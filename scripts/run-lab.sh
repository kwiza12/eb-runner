#!/usr/bin/env bash
set -euo pipefail


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
SOCAT_PID=""
K3S_STARTED="false"
LAB_IMAGE="${LAB_IMAGE:?LAB_IMAGE is required}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.35.3-k3s1}"
PRIVILEGED="${PRIVILEGED:-false}"
WEB_PORT="${WEB_PORT:-0}"
CONTENT_BASE="${CONTENT_BASE:-}"
CADDY_PID=""
CADDY_PORT=8080
EXPOSED_WEB_PORT=13080

mkdir -p "$ARTIFACTS_DIR"


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
  [ -n "$CADDY_PID" ] && kill "$CADDY_PID" 2>/dev/null || true
  [ -n "$SOCAT_PID" ] && kill "$SOCAT_PID" 2>/dev/null || true
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  callback "workflow-complete" "{\"session_id\":\"${SESSION_ID}\"}"
  log "Cleanup done."
}
trap cleanup EXIT

# --- Cluster detection ---
needs_k3s() {
  case "$CHALLENGE_NAME" in
    k8s-*|fix-crashlooping-pod|aiops-auto-diagnostics|aiops-auto-restart-pods|aiops-auto-scale-on-anomaly|aiops-self-healing-operator) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Privilege detection ---
needs_privileged() {
  [ "$PRIVILEGED" = "true" ]
}

# --- AIOps image detection ---
needs_aiops_image() {
  case "$CHALLENGE_NAME" in
    aiops-*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- start_k3s ---
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

# --- wait_k3s_ready ---
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

# --- apply ---
run_task() {
  local cmd_id="$1" task_json="$2" cmd_type="$3"

  if [ "$cmd_type" = "validate" ]; then
    log "Validating..."
    local task_name
    task_name=$(echo "$task_json" | jq -r '.challenge_name // ""')
    local validation_script
    validation_script=$(echo "$task_json" | jq -r '.challenge.validation_script // "validate.sh"')

    local validate_raw="${CONTENT_BASE}/challenges/${task_name}/${validation_script}"
    log "Downloading validation script: ${validate_raw}"
    curl -sf "$validate_raw" -o "/tmp/validate_${SESSION_ID:0:8}.sh" 2>/dev/null

    if [ -f "/tmp/validate_${SESSION_ID:0:8}.sh" ]; then
      docker cp "/tmp/validate_${SESSION_ID:0:8}.sh" "${CONTAINER_NAME}:/home/${CONTAINER_USER}/${validation_script}"
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
      log "PASS: $output"
    else
      report_result "$cmd_id" "false" "$output" "validate"
      log "FAIL: $output"
    fi
    return
  fi

  
  log "Applying..."
  local packages pre_install namespace
  packages=$(echo "$task_json" | jq -r '.challenge.packages // [] | join(" ")')
  pre_install=$(echo "$task_json" | jq -r '.challenge.pre_install // [] | join(" ")')
  namespace=$(echo "$task_json" | jq -r '.challenge.namespace // ""')

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

  local task_name
  task_name=$(echo "$task_json" | jq -r '.challenge_name // ""')
  if [ -n "$task_name" ]; then
    log "Fetching bundle: ${task_name}"
    local bundle_url="${CALLBACK_URL}/${SESSION_ID}/challenge/${task_name}/bundle"
    local bundle_file="/tmp/task-bundle.tar.gz"
    curl -sf "$bundle_url" \
      -H "X-Callback-Token: ${CALLBACK_TOKEN}" \
      -o "$bundle_file" || log "WARN: Failed to download bundle"

    if [ -f "$bundle_file" ]; then
      local extract_dir="/tmp/task-extract"
      rm -rf "$extract_dir" && mkdir -p "$extract_dir"
      tar xzf "$bundle_file" -C "$extract_dir" 2>/dev/null || true

      local files_dir
      files_dir=$(find "$extract_dir" -type d -name "files" -path "*/${task_name}/*" | head -1)
      if [ -n "$files_dir" ]; then
        local file_specs
        file_specs=$(echo "$task_json" | jq -c '.challenge.files // []')
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
  setup_cmds=$(echo "$task_json" | jq -r '.challenge.setup // []')
  echo "$setup_cmds" | jq -r '.[]' 2>/dev/null | while read -r cmd; do
    if [ -n "$cmd" ]; then
      log "  Running setup: ${cmd}"
      docker exec "$CONTAINER_NAME" sudo -u "$CONTAINER_USER" bash -c "$cmd" || true
    fi
  done

  # Cleanup files marked for cleanup
  echo "$task_json" | jq -c '.challenge.files // [] | .[] | select(.cleanup == true)' 2>/dev/null | while read -r file_spec; do
    local dest
    dest=$(echo "$file_spec" | jq -r '.dest')
    dest="${dest/#\~\//\/home\/${CONTAINER_USER}\/}"
    docker exec "$CONTAINER_NAME" rm -f "$dest" 2>/dev/null || true
    log "  Cleaned up: ${dest}"
  done

  report_result "$cmd_id" "true" "Applied successfully" "apply"
  log "Applied."
}

# --- 1. k3s ---
KUBECONFIG_FILE=""
if needs_k3s; then
  log "Starting k3s..."
  docker pull "$K3S_IMAGE" >/dev/null 2>&1 || log "WARN: k3s pull failed, trying cached"
  start_k3s || log "WARN: k3s failed to start"
fi

# --- 2. Container ---
EFFECTIVE_IMAGE="$LAB_IMAGE"
if needs_aiops_image; then
  AIOPS_IMAGE="${AIOPS_LAB_IMAGE:-karthickk/enterbash-aiops:latest}"
  log "AIOps challenge detected, using image: ${AIOPS_IMAGE}"
  EFFECTIVE_IMAGE="$AIOPS_IMAGE"
fi

log "Pulling image: ${EFFECTIVE_IMAGE}"
docker pull "$EFFECTIVE_IMAGE" >/dev/null 2>&1 || log "WARN: pull failed, trying cached image"

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
  log "Privileged mode"
  LAB_RUN_ARGS+=(--privileged)
fi

docker run -d "${LAB_RUN_ARGS[@]}" "$EFFECTIVE_IMAGE" sleep infinity

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

log "Starting ttyd on port ${TTYD_PORT}"
THEME='{"background":"#000000","foreground":"#c7c7c7","cursor":"#2196F3","cursorAccent":"#000000","selectionBackground":"#2196F333","black":"#000000","red":"#c91b00","green":"#00c200","yellow":"#c7c400","blue":"#0225c7","magenta":"#c930c7","cyan":"#00c5c7","white":"#c7c7c7","brightBlack":"#686868","brightRed":"#ff6e67","brightGreen":"#5ffa68","brightYellow":"#fffc67","brightBlue":"#6871ff","brightMagenta":"#ff77ff","brightCyan":"#60fdff","brightWhite":"#ffffff"}'

TTYD_BASE_PATH=""
if [ "$WEB_PORT" != "0" ] && [ -n "$WEB_PORT" ]; then
  TTYD_BASE_PATH="/terminal"
fi

ttyd \
  --port "$TTYD_PORT" \
  --writable \
  ${TTYD_BASE_PATH:+--base-path "$TTYD_BASE_PATH"} \
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

# --- 3b. Caddy reverse proxy (when web_port is set) ---
TUNNEL_TARGET_PORT="$TTYD_PORT"
if [ "$WEB_PORT" != "0" ] && [ -n "$WEB_PORT" ]; then
  log "Starting web service inside container on port ${WEB_PORT}..."
  # Start services based on what's available
  # Configure Grafana to allow iframe embedding (X-Frame-Options)
  docker exec "$CONTAINER_NAME" bash -c "
    if [ -f /etc/grafana/grafana.ini ]; then
      sed -i 's/;allow_embedding = .*/allow_embedding = true/' /etc/grafana/grafana.ini
      sed -i 's/allow_embedding = false/allow_embedding = true/' /etc/grafana/grafana.ini
      # Also add it if not present at all
      grep -q 'allow_embedding' /etc/grafana/grafana.ini || \
        sed -i '/\[security\]/a allow_embedding = true' /etc/grafana/grafana.ini
    fi
  " || true

  docker exec -d "$CONTAINER_NAME" bash -c "
    # Start services based on what's available
    if command -v grafana-server >/dev/null 2>&1; then
      grafana-server --homepath=/usr/share/grafana --config=/etc/grafana/grafana.ini &
    fi
    if command -v prometheus >/dev/null 2>&1 && [ -f /etc/prometheus/prometheus.yml ]; then
      prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/tmp/prometheus &
    fi
    if command -v node_exporter >/dev/null 2>&1; then
      node_exporter &
    fi
    # Keep this exec session alive so children survive
    sleep infinity
  "

  # Wait for web service to be ready
  for i in $(seq 1 30); do
    if docker exec "$CONTAINER_NAME" curl -sf "http://localhost:${WEB_PORT}/" > /dev/null 2>&1; then
      log "Web service ready on container port ${WEB_PORT}"
      break
    fi
    sleep 2
  done

  log "Starting Caddy reverse proxy..."
  # socat bridge: host port -> container port via docker exec
  socat TCP-LISTEN:${EXPOSED_WEB_PORT},fork,reuseaddr \
    EXEC:"docker exec -i ${CONTAINER_NAME} socat STDIO TCP\:localhost\:${WEB_PORT}" &
  SOCAT_PID=$!
  sleep 1

  CADDYFILE="/tmp/Caddyfile"
  cat > "$CADDYFILE" << CADDYEOF
:${CADDY_PORT} {
  handle /terminal/* {
    reverse_proxy localhost:${TTYD_PORT}
  }
  handle {
    reverse_proxy localhost:${EXPOSED_WEB_PORT}
  }
}
CADDYEOF
  caddy run --config "$CADDYFILE" > /tmp/caddy.log 2>&1 &
  CADDY_PID=$!
  sleep 1
  if ! kill -0 "$CADDY_PID" 2>/dev/null; then
    log "WARN: Caddy failed to start, falling back to direct ttyd tunnel"
    cat /tmp/caddy.log
  else
    log "Caddy running (PID: ${CADDY_PID})"
    TUNNEL_TARGET_PORT="$CADDY_PORT"
  fi
fi

log "Starting cloudflared tunnel..."
TUNNEL_LOG="/tmp/cloudflared.log"
cloudflared tunnel --url "http://localhost:${TUNNEL_TARGET_PORT}" --no-autoupdate > "$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!

# --- 4. Background apply ---
APPLY_BG_PID=""
(
  for i in $(seq 1 10); do
    RESP=$(poll_commands)
    CMD=$(echo "$RESP" | jq -c '.data.commands // [] | map(select(.type == "apply")) | .[0] // empty' 2>/dev/null)
    if [ -n "$CMD" ] && [ "$CMD" != "null" ] && [ "$CMD" != "empty" ]; then
      CMD_ID=$(echo "$CMD" | jq -r '.id')
      log "[apply-bg] Got task ${CMD_ID}, running..."
      run_task "$CMD_ID" "$CMD" "apply"
      log "[apply-bg] Done."
      exit 0
    fi
    sleep 1
  done
  log "[apply-bg] WARN: no task received after 10s"
) &
APPLY_BG_PID=$!

# --- 5. Tunnel URL ---
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

# --- 6. DNS wait ---
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

# --- 7. Sync ---
if [ -n "$APPLY_BG_PID" ]; then
  log "Waiting for apply..."
  wait "$APPLY_BG_PID" 2>/dev/null || true
fi

# --- 8. Ready ---
callback "session-ready" "{\"session_id\":\"${SESSION_ID}\",\"tunnel_url\":\"${TUNNEL_URL}/\"}"
log "Session reported as ready."

# --- 9. Main loop ---
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
        run_task "$CMD_ID" "$cmd_json" "$CMD_TYPE"
      done
    fi
  fi

  sleep "$POLL_INTERVAL"
done

log "Lab session complete."
