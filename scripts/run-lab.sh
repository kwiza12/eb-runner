#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
SESSION_ID="${SESSION_ID:?SESSION_ID is required}"
CALLBACK_URL="${CALLBACK_URL:?CALLBACK_URL is required}"
CALLBACK_TOKEN="${CALLBACK_TOKEN:?CALLBACK_TOKEN is required}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-55}"
CHALLENGE_NAME="${CHALLENGE_NAME:?CHALLENGE_NAME is required}"

CONTAINER_NAME="eb-${SESSION_ID:0:12}"
K3S_NAME="k3s-${SESSION_ID:0:12}"
NETWORK_NAME="ebnet-${SESSION_ID:0:12}"
CONTAINER_USER="runner"
TTYD_PORT=7681
ARTIFACTS_DIR="/tmp/lab-artifacts"
TTYD_PID=""
TUNNEL_PID=""
K3S_STARTED="false"
LAB_IMAGE="${LAB_IMAGE:-karthickk/enterbash:latest}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.35.3-k3s1}"
PRIVILEGED="${PRIVILEGED:-false}"

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
  docker cp "${CONTAINER_NAME}:/home/${CONTAINER_USER}/.bash_history" "${ARTIFACTS_DIR}/bash_history" 2>/dev/null || true
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  if [ "$K3S_STARTED" = "true" ]; then
    docker logs "$K3S_NAME" > "${ARTIFACTS_DIR}/k3s.log" 2>&1 || true
    docker rm -f "$K3S_NAME" 2>/dev/null || true
  fi
  docker network rm "$NETWORK_NAME" 2>/dev/null || true
  [ -n "$TTYD_PID" ] && kill "$TTYD_PID" 2>/dev/null || true
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  callback "workflow-complete" "{\"session_id\":\"${SESSION_ID}\"}"
  log "Cleanup done."
}
trap cleanup EXIT

# --- Detect if this challenge needs a k8s cluster ---
# Triggered by k8s-* prefix or the standalone fix-crashlooping-pod challenge.
needs_k3s() {
  case "$CHALLENGE_NAME" in
    k8s-*|fix-crashlooping-pod) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Detect if this challenge needs a privileged container ---
# Driven by the 'privileged: true' field in challenge.yaml, passed as PRIVILEGED env var.
needs_privileged() {
  [ "$PRIVILEGED" = "true" ]
}

# --- start_k3s: brings up a k3s server in a sibling container on a dedicated network ---
# Sets global KUBECONFIG_FILE on success.
start_k3s() {
  log "Creating docker network ${NETWORK_NAME}" >&2
  docker network create "$NETWORK_NAME" >/dev/null

  log "Starting k3s server (${K3S_IMAGE})..." >&2
  docker run -d \
    --name "$K3S_NAME" \
    --hostname "$K3S_NAME" \
    --network "$NETWORK_NAME" \
    --privileged \
    --tmpfs /run \
    --tmpfs /var/run \
    -e K3S_KUBECONFIG_MODE=644 \
    "$K3S_IMAGE" \
    server \
      --disable=traefik \
      --disable=servicelb \
      --disable=metrics-server \
      --disable=local-storage \
      --disable-network-policy \
      --disable-helm-controller \
      --tls-san="$K3S_NAME" \
    >/dev/null

  K3S_STARTED="true"
  log "Waiting for k3s kubeconfig to be written..." >&2
  local ok="false"
  for i in $(seq 1 60); do
    if docker exec "$K3S_NAME" test -f /etc/rancher/k3s/k3s.yaml 2>/dev/null; then
      ok="true"
      break
    fi
    sleep 1
  done
  if [ "$ok" != "true" ]; then
    log "ERROR: k3s kubeconfig never appeared" >&2
    return 1
  fi

  # Extract kubeconfig and rewrite server URL to use the network hostname
  KUBECONFIG_FILE="/tmp/kubeconfig-${SESSION_ID:0:12}"
  docker exec "$K3S_NAME" cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG_FILE"
  sed -i "s|server: https://127.0.0.1:6443|server: https://${K3S_NAME}:6443|g" "$KUBECONFIG_FILE"
  chmod 644 "$KUBECONFIG_FILE"
  log "k3s kubeconfig at ${KUBECONFIG_FILE}" >&2
}

# --- wait_k3s_ready: polls until the node is Ready (called after lab container exists) ---
wait_k3s_ready() {
  log "Waiting for k3s node to become Ready..."
  for i in $(seq 1 60); do
    local status
    status=$(docker exec "$CONTAINER_NAME" sudo -u "$CONTAINER_USER" \
      kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1 || true)
    if [ "$status" = "Ready" ]; then
      log "k3s node is Ready after ${i}s"
      return 0
    fi
    sleep 1
  done
  log "WARN: k3s did not become Ready within 60s"
  return 1
}

# --- apply_challenge: handles both apply and validate commands ---
apply_challenge() {
  local cmd_id="$1" challenge_json="$2" cmd_type="$3"

  if [ "$cmd_type" = "validate" ]; then
    log "Running validation..."
    local challenge_name
    challenge_name=$(echo "$challenge_json" | jq -r '.challenge_name // ""')
    local validation_script
    validation_script=$(echo "$challenge_json" | jq -r '.challenge.validation_script // "validate.sh"')

    local validate_raw="https://raw.githubusercontent.com/enterbash/enter-bash-content/main/challenges/${challenge_name}/${validation_script}"
    log "Downloading validation script: ${validate_raw}"
    curl -sf "$validate_raw" -o "/tmp/validate_${challenge_name}.sh" 2>/dev/null

    if [ -f "/tmp/validate_${challenge_name}.sh" ]; then
      docker cp "/tmp/validate_${challenge_name}.sh" "${CONTAINER_NAME}:/home/${CONTAINER_USER}/${validation_script}"
      docker exec "$CONTAINER_NAME" chown "${CONTAINER_USER}:${CONTAINER_USER}" "/home/${CONTAINER_USER}/${validation_script}"
      docker exec "$CONTAINER_NAME" chmod +x "/home/${CONTAINER_USER}/${validation_script}"
    fi

    local output exit_code
    set +e
    output=$(docker exec "$CONTAINER_NAME" sudo -u "$CONTAINER_USER" bash -c "
      cd /home/${CONTAINER_USER} && \
      if [ -f '${validation_script}' ]; then
        bash '${validation_script}' 2>&1
      else
        echo 'Validation script not found' && exit 1
      fi
    " 2>&1)
    exit_code=$?
    set -e

    if [ $exit_code -eq 0 ]; then
      report_result "$cmd_id" "true" "$output" "validate"
      log "Validation PASSED: $output"
    else
      report_result "$cmd_id" "false" "$output" "validate"
      log "Validation FAILED: $output"
    fi
    return
  fi

  # Apply challenge
  log "Applying challenge..."
  local packages pre_install namespace
  packages=$(echo "$challenge_json" | jq -r '.challenge.packages // [] | join(" ")')
  pre_install=$(echo "$challenge_json" | jq -r '.challenge.pre_install // [] | join(" ")')
  namespace=$(echo "$challenge_json" | jq -r '.challenge.namespace // ""')

  # Image is pre-baked; only install if something exotic is requested
  if [ -n "$packages" ] && [ "$packages" != "null" ]; then
    local missing
    missing=$(docker exec "$CONTAINER_NAME" bash -c "
      MISS=''
      for pkg in ${packages}; do
        dpkg -s \"\$pkg\" >/dev/null 2>&1 || MISS=\"\$MISS \$pkg\"
      done
      echo \"\$MISS\"
    " | xargs)
    if [ -n "$missing" ]; then
      log "Installing missing packages: ${missing}"
      docker exec "$CONTAINER_NAME" bash -c "apt-get update -qq && apt-get install -y -qq ${missing}" || true
    else
      log "All packages pre-installed, skipping apt"
    fi
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
      local extract_dir="/tmp/challenge-extract"
      rm -rf "$extract_dir" && mkdir -p "$extract_dir"
      tar xzf "$bundle_file" -C "$extract_dir" 2>/dev/null || true

      local files_dir
      files_dir=$(find "$extract_dir" -type d -name "files" -path "*/${challenge_name}/*" | head -1)
      if [ -n "$files_dir" ]; then
        local file_specs
        file_specs=$(echo "$challenge_json" | jq -c '.challenge.files // []')
        echo "$file_specs" | jq -c '.[]' 2>/dev/null | while read -r file_spec; do
          local src dest executable
          src=$(echo "$file_spec" | jq -r '.source')
          dest=$(echo "$file_spec" | jq -r '.dest')
          executable=$(echo "$file_spec" | jq -r '.executable // false')

          dest="${dest/#\~\//\/home\/${CONTAINER_USER}\/}"

          local src_path="${files_dir}/../${src}"
          if [ -f "$src_path" ]; then
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

# --- 1. Start k3s in background (if needed) ---
KUBECONFIG_FILE=""
if needs_k3s; then
  log "Challenge requires Kubernetes, starting k3s..."
  docker pull "$K3S_IMAGE" >/dev/null 2>&1 || log "WARN: k3s pull failed, trying cached"
  start_k3s || log "WARN: k3s failed to start"
fi

# --- 2. Start lab container ---
log "Pulling image: ${LAB_IMAGE}"
docker pull "$LAB_IMAGE" >/dev/null 2>&1 || log "WARN: pull failed, trying cached image"

log "Starting container: ${CONTAINER_NAME}"
LAB_RUN_ARGS=(
  --name "$CONTAINER_NAME"
  --hostname "$CONTAINER_NAME"
  --memory=1g
  --cpus=1
  -v /var/run/docker.sock:/var/run/docker.sock
)
if needs_k3s; then
  # Attach to the same network as k3s so `kubectl` can reach the server by hostname
  LAB_RUN_ARGS+=(--network "$NETWORK_NAME")
fi
if needs_privileged; then
  log "Challenge requires privileged container (kernel ops)"
  LAB_RUN_ARGS+=(--privileged)
fi

docker run -d "${LAB_RUN_ARGS[@]}" "$LAB_IMAGE" sleep infinity

# Remap docker group GID to match host socket
docker exec "$CONTAINER_NAME" bash -c "
  SOCK_GID=\$(stat -c '%g' /var/run/docker.sock) && \
  CURRENT_GID=\$(getent group docker | cut -d: -f3) && \
  if [ \"\$SOCK_GID\" != \"\$CURRENT_GID\" ]; then \
    groupmod -g \$SOCK_GID docker 2>/dev/null || true; \
  fi
"

# Inject kubeconfig into lab container if k3s is active
if needs_k3s && [ -n "$KUBECONFIG_FILE" ] && [ -f "$KUBECONFIG_FILE" ]; then
  log "Injecting kubeconfig into lab container..."
  docker exec "$CONTAINER_NAME" mkdir -p "/home/${CONTAINER_USER}/.kube"
  docker cp "$KUBECONFIG_FILE" "${CONTAINER_NAME}:/home/${CONTAINER_USER}/.kube/config"
  docker exec "$CONTAINER_NAME" chown -R "${CONTAINER_USER}:${CONTAINER_USER}" "/home/${CONTAINER_USER}/.kube"
  docker exec "$CONTAINER_NAME" chmod 600 "/home/${CONTAINER_USER}/.kube/config"
fi

log "Container ready."

# --- Wait for k3s to become Ready (so setup scripts using kubectl work) ---
if needs_k3s; then
  wait_k3s_ready || log "WARN: k3s not ready — kubectl commands may fail until node comes up"
fi

# --- 2. Start ttyd ---
log "Starting ttyd on port ${TTYD_PORT}"
THEME='{"background":"#000000","foreground":"#c7c7c7","cursor":"#2196F3","cursorAccent":"#000000","selectionBackground":"#2196F333","black":"#000000","red":"#c91b00","green":"#00c200","yellow":"#c7c400","blue":"#0225c7","magenta":"#c930c7","cyan":"#00c5c7","white":"#c7c7c7","brightBlack":"#686868","brightRed":"#ff6e67","brightGreen":"#5ffa68","brightYellow":"#fffc67","brightBlue":"#6871ff","brightMagenta":"#ff77ff","brightCyan":"#60fdff","brightWhite":"#ffffff"}'

ttyd \
  --port "$TTYD_PORT" \
  --writable \
  -t fontSize=17 \
  -t reconnect=0 \
  -t "theme=${THEME}" \
  docker exec -it "$CONTAINER_NAME" sudo -u "$CONTAINER_USER" -i &
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

# --- 4. Apply initial challenge in background while tunnel propagates ---
# The worker created the apply command at session-create time so it's
# immediately available. Running in background lets us overlap file copy
# with DNS propagation (both take ~5-10s).
APPLY_BG_PID=""
(
  for i in $(seq 1 10); do
    RESP=$(poll_commands)
    CMD=$(echo "$RESP" | jq -c '.data.commands // [] | map(select(.type == "apply")) | .[0] // empty' 2>/dev/null)
    if [ -n "$CMD" ] && [ "$CMD" != "null" ] && [ "$CMD" != "empty" ]; then
      CMD_ID=$(echo "$CMD" | jq -r '.id')
      log "[apply-bg] Got apply command ${CMD_ID}, running..."
      apply_challenge "$CMD_ID" "$CMD" "apply"
      log "[apply-bg] Done."
      exit 0
    fi
    sleep 1
  done
  log "[apply-bg] WARN: no apply command received after 10s"
) &
APPLY_BG_PID=$!

# --- 5. Wait for tunnel URL (up to 30s) ---
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

# --- 6. Wait for tunnel DNS to propagate ---
log "Waiting for tunnel DNS to propagate..."
TUNNEL_READY=false
for i in $(seq 1 30); do
  if curl -sf --max-time 5 "${TUNNEL_URL}/" > /dev/null 2>&1; then
    TUNNEL_READY=true
    log "Tunnel is accessible after ${i} attempts"
    break
  fi
  sleep 2
done

if [ "$TUNNEL_READY" = "false" ]; then
  log "WARN: Tunnel may not be ready yet, reporting anyway"
fi

# --- 7. Wait for background apply to finish ---
if [ -n "$APPLY_BG_PID" ]; then
  log "Waiting for challenge files to finish applying..."
  wait "$APPLY_BG_PID" 2>/dev/null || true
fi

# --- 8. Report session ready (tunnel live + files in place) ---
callback "session-ready" "{\"session_id\":\"${SESSION_ID}\",\"tunnel_url\":\"${TUNNEL_URL}/\"}"
log "Session reported as ready."

# --- 9. Main loop: poll for validate commands + heartbeat ---
DEADLINE=$(($(date +%s) + TIMEOUT_MINUTES * 60))
HEARTBEAT_INTERVAL=15
POLL_INTERVAL=5
LAST_HEARTBEAT=0

log "Entering main loop (timeout: ${TIMEOUT_MINUTES}m)"

while true; do
  NOW=$(date +%s)

  if [ "$NOW" -ge "$DEADLINE" ]; then
    log "Session timed out."
    break
  fi

  if [ $((NOW - LAST_HEARTBEAT)) -ge "$HEARTBEAT_INTERVAL" ]; then
    ACTION=$(heartbeat)
    LAST_HEARTBEAT=$NOW
    if [ "$ACTION" = "stop" ]; then
      log "Received stop signal."
      break
    fi
  fi

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
