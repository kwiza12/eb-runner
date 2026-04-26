#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
SESSION_ID="${SESSION_ID:?SESSION_ID is required}"
CALLBACK_URL="${CALLBACK_URL:?CALLBACK_URL is required}"
CALLBACK_TOKEN="${CALLBACK_TOKEN:?CALLBACK_TOKEN is required}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-55}"
CHALLENGE_NAME="${CHALLENGE_NAME:?CHALLENGE_NAME is required}"

CONTAINER_NAME="eb-${SESSION_ID:0:12}"
CONTAINER_USER="learner"
TTYD_PORT=7681
ARTIFACTS_DIR="/tmp/lab-artifacts"
TTYD_PID=""
TUNNEL_PID=""

mkdir -p "$ARTIFACTS_DIR"

# --- Helper functions ---
log() { echo "[$(date '+%H:%M:%S')] $*"; }

callback() {
  local endpoint="$1"
  local data="$2"
  curl -sf -X POST "${CALLBACK_URL}/${endpoint}" \
    -H "Content-Type: application/json" \
    -H "X-Callback-Token: ${CALLBACK_TOKEN}" \
    -d "$data" || log "WARN: callback to ${endpoint} failed"
}

poll_commands() {
  curl -sf "${CALLBACK_URL}/${SESSION_ID}/commands" \
    -H "X-Callback-Token: ${CALLBACK_TOKEN}" 2>/dev/null || echo '{"ok":false}'
}

report_result() {
  local cmd_id="$1" success="$2" output="$3" type="$4"
  callback "${SESSION_ID}/command-result" \
    "{\"command_id\":\"${cmd_id}\",\"success\":${success},\"output\":$(echo "$output" | jq -Rs .),\"type\":\"${type}\"}"
}

heartbeat() {
  local resp
  resp=$(curl -sf -X POST "${CALLBACK_URL}/${SESSION_ID}/heartbeat" \
    -H "Content-Type: application/json" \
    -H "X-Callback-Token: ${CALLBACK_TOKEN}" \
    -d '{}' 2>/dev/null || echo '{"ok":false}')
  echo "$resp" | jq -r '.data.action // "continue"'
}

cleanup() {
  log "Cleaning up..."
  # Save bash history as artifact
  docker cp "${CONTAINER_NAME}:/home/${CONTAINER_USER}/.bash_history" "${ARTIFACTS_DIR}/bash_history" 2>/dev/null || true
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  [ -n "$TTYD_PID" ] && kill "$TTYD_PID" 2>/dev/null || true
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  # Report workflow complete
  callback "workflow-complete" "{\"session_id\":\"${SESSION_ID}\"}"
  log "Cleanup done."
}
trap cleanup EXIT

# --- 1. Start Docker container ---
log "Starting container: ${CONTAINER_NAME}"
docker run -d \
  --name "$CONTAINER_NAME" \
  --hostname learner \
  --memory=1g \
  --cpus=1 \
  ubuntu:24.04 \
  sleep infinity

# Create learner user with sudo
docker exec "$CONTAINER_NAME" bash -c "
  useradd -m -s /bin/bash ${CONTAINER_USER} && \
  apt-get update -qq && \
  apt-get install -y -qq sudo bash-completion curl wget ca-certificates jq && \
  echo '${CONTAINER_USER} ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers && \
  apt-get clean && rm -rf /var/lib/apt/lists/*
"
log "Container ready."

# --- 2. Start ttyd ---
log "Starting ttyd on port ${TTYD_PORT}"
ttyd \
  --port "$TTYD_PORT" \
  --writable \
  docker exec -i "$CONTAINER_NAME" sudo -u "$CONTAINER_USER" -i &
TTYD_PID=$!
sleep 2

if ! kill -0 "$TTYD_PID" 2>/dev/null; then
  log "ERROR: ttyd failed to start"
  exit 1
fi
log "ttyd running (PID: ${TTYD_PID})"

# --- 3. Start cloudflared tunnel ---
log "Starting cloudflared tunnel..."
TUNNEL_LOG="/tmp/cloudflared.log"
cloudflared tunnel --url "http://localhost:${TTYD_PORT}" --no-autoupdate > "$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!

# Wait for tunnel URL (up to 30s)
TUNNEL_URL=""
for i in $(seq 1 30); do
  TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)
  if [ -n "$TUNNEL_URL" ]; then break; fi
  sleep 1
done

if [ -z "$TUNNEL_URL" ]; then
  log "ERROR: Failed to get tunnel URL"
  cat "$TUNNEL_LOG"
  exit 1
fi
log "Tunnel URL: ${TUNNEL_URL}"

# Wait for tunnel to be accessible (DNS propagation)
log "Waiting for tunnel DNS to propagate..."
TUNNEL_READY=false
for i in $(seq 1 30); do
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "${TUNNEL_URL}/" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" != "000" ]; then
    TUNNEL_READY=true
    log "Tunnel is accessible (HTTP ${HTTP_CODE})"
    break
  fi
  sleep 2
done

if [ "$TUNNEL_READY" = "false" ]; then
  log "WARN: Tunnel DNS not yet propagated, reporting anyway"
fi

# --- 4. Report session ready ---
callback "session-ready" "{\"session_id\":\"${SESSION_ID}\",\"tunnel_url\":\"${TUNNEL_URL}/\"}"
log "Session reported as ready."

# --- 5. Poll for commands and apply ---
apply_challenge() {
  local cmd_id="$1" challenge_json="$2" cmd_type="$3"

  if [ "$cmd_type" = "validate" ]; then
    log "Running validation..."
    # Download and run validation script
    local challenge_name
    challenge_name=$(echo "$challenge_json" | jq -r '.challenge_name // ""')
    local validation_script
    validation_script=$(echo "$challenge_json" | jq -r '.challenge.validation_script // "validate.sh"')

    # Try to run validate.sh from the container
    local output
    output=$(docker exec "$CONTAINER_NAME" sudo -u "$CONTAINER_USER" bash -c "
      cd /home/${CONTAINER_USER} && \
      if [ -f '${validation_script}' ]; then
        bash '${validation_script}' 2>&1
      else
        echo 'Validation script not found' && exit 1
      fi
    " 2>&1) || true
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
      report_result "$cmd_id" "true" "$output" "validate"
      log "Validation PASSED"
    else
      report_result "$cmd_id" "false" "$output" "validate"
      log "Validation FAILED"
    fi
    return
  fi

  # Apply challenge
  log "Applying challenge..."
  local packages pre_install namespace
  packages=$(echo "$challenge_json" | jq -r '.challenge.packages // [] | join(" ")')
  pre_install=$(echo "$challenge_json" | jq -r '.challenge.pre_install // [] | join(" ")')
  namespace=$(echo "$challenge_json" | jq -r '.challenge.namespace // ""')

  # Install packages
  if [ -n "$packages" ] && [ "$packages" != "null" ]; then
    log "Installing packages: ${packages}"
    docker exec "$CONTAINER_NAME" bash -c "apt-get update -qq && apt-get install -y -qq ${packages}" || true
  fi

  # Download and extract challenge files
  local challenge_name
  challenge_name=$(echo "$challenge_json" | jq -r '.challenge_name // ""')
  if [ -n "$challenge_name" ]; then
    log "Downloading challenge bundle: ${challenge_name}"
    local bundle_url="${CALLBACK_URL}/${SESSION_ID}/challenge/${challenge_name}/bundle"
    local bundle_file="/tmp/challenge-bundle.tar.gz"
    curl -sf "$bundle_url" \
      -H "X-Callback-Token: ${CALLBACK_TOKEN}" \
      -o "$bundle_file" || log "WARN: Failed to download bundle"

    if [ -f "$bundle_file" ]; then
      # Extract and find the challenge directory
      local extract_dir="/tmp/challenge-extract"
      rm -rf "$extract_dir" && mkdir -p "$extract_dir"
      tar xzf "$bundle_file" -C "$extract_dir" 2>/dev/null || true

      # Find the challenge files directory
      local files_dir
      files_dir=$(find "$extract_dir" -type d -name "files" -path "*/${challenge_name}/*" | head -1)
      if [ -n "$files_dir" ]; then
        # Copy files into container based on challenge spec
        local file_specs
        file_specs=$(echo "$challenge_json" | jq -c '.challenge.files // []')
        echo "$file_specs" | jq -c '.[]' 2>/dev/null | while read -r file_spec; do
          local src dest executable cleanup_flag
          src=$(echo "$file_spec" | jq -r '.source')
          dest=$(echo "$file_spec" | jq -r '.dest')
          executable=$(echo "$file_spec" | jq -r '.executable // false')
          cleanup_flag=$(echo "$file_spec" | jq -r '.cleanup // false')

          # Resolve ~/  to /home/learner/
          dest="${dest/#\~\//\/home\/${CONTAINER_USER}\/}"

          local src_path="${files_dir}/../${src}"
          if [ -f "$src_path" ]; then
            # Ensure dest directory exists
            local dest_dir
            dest_dir=$(dirname "$dest")
            docker exec "$CONTAINER_NAME" mkdir -p "$dest_dir"
            docker cp "$src_path" "${CONTAINER_NAME}:${dest}"
            docker exec "$CONTAINER_NAME" chown "${CONTAINER_USER}:${CONTAINER_USER}" "$dest"
            if [ "$executable" = "true" ]; then
              docker exec "$CONTAINER_NAME" chmod +x "$dest"
            fi
            log "  Copied: ${src} -> ${dest}"
          fi
        done
      fi
      rm -rf "$extract_dir" "$bundle_file"
    fi
  fi

  # Run setup commands
  local setup_cmds
  setup_cmds=$(echo "$challenge_json" | jq -r '.challenge.setup // []')
  echo "$setup_cmds" | jq -r '.[]' 2>/dev/null | while read -r cmd; do
    if [ -n "$cmd" ]; then
      log "  Running setup: ${cmd}"
      docker exec "$CONTAINER_NAME" sudo -u "$CONTAINER_USER" bash -c "$cmd" || true
    fi
  done

  # Cleanup files marked for cleanup
  echo "$challenge_json" | jq -c '.challenge.files // [] | .[] | select(.cleanup == true)' 2>/dev/null | while read -r file_spec; do
    local dest
    dest=$(echo "$file_spec" | jq -r '.dest')
    dest="${dest/#\~\//\/home\/${CONTAINER_USER}\/}"
    docker exec "$CONTAINER_NAME" rm -f "$dest" 2>/dev/null || true
    log "  Cleaned up: ${dest}"
  done

  report_result "$cmd_id" "true" "Challenge applied successfully" "apply"
  log "Challenge applied."
}

# --- 6. Main loop: poll commands + heartbeat ---
DEADLINE=$(($(date +%s) + TIMEOUT_MINUTES * 60))
HEARTBEAT_INTERVAL=15
POLL_INTERVAL=5
LAST_HEARTBEAT=0

log "Entering main loop (timeout: ${TIMEOUT_MINUTES}m)"

while true; do
  NOW=$(date +%s)

  # Check timeout
  if [ "$NOW" -ge "$DEADLINE" ]; then
    log "Session timed out."
    break
  fi

  # Heartbeat
  if [ $((NOW - LAST_HEARTBEAT)) -ge "$HEARTBEAT_INTERVAL" ]; then
    ACTION=$(heartbeat)
    LAST_HEARTBEAT=$NOW
    if [ "$ACTION" = "stop" ]; then
      log "Received stop signal."
      break
    fi
  fi

  # Poll for commands
  RESPONSE=$(poll_commands)
  if echo "$RESPONSE" | jq -e '.ok' > /dev/null 2>&1; then
    ACTION=$(echo "$RESPONSE" | jq -r '.data.action // "continue"')
    if [ "$ACTION" = "stop" ]; then
      log "Received stop signal from commands."
      break
    fi

    COMMANDS=$(echo "$RESPONSE" | jq -c '.data.commands // []')
    CMD_COUNT=$(echo "$COMMANDS" | jq 'length')

    if [ "$CMD_COUNT" -gt 0 ]; then
      echo "$COMMANDS" | jq -c '.[]' | while read -r cmd_json; do
        CMD_ID=$(echo "$cmd_json" | jq -r '.id')
        CMD_TYPE=$(echo "$cmd_json" | jq -r '.type')
        apply_challenge "$CMD_ID" "$cmd_json" "$CMD_TYPE"
      done
    fi
  fi

  sleep "$POLL_INTERVAL"
done

log "Lab session complete."
