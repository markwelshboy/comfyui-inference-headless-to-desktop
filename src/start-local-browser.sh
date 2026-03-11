#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"

SCREEN_GEOM="${SCREEN_GEOM:-1440x900x24}"
NOVNC_PORT="${NOVNC_PORT:-8988}"
VNC_PORT="${VNC_PORT:-5090}"
START_URL="${START_URL:-http://127.0.0.1:8288}"

# Use Chrome by default; override if you want something else
BROWSER_CMD="${BROWSER_CMD:-google-chrome --no-sandbox --disable-gpu --disable-gpu-compositing}"

GUI_STATE_DIR="${GUI_STATE_DIR:-/tmp/local-browser}"
mkdir -p "${GUI_STATE_DIR}" /tmp/.X11-unix

XVFB_LOG="${GUI_STATE_DIR}/xvfb.log"
OPENBOX_LOG="${GUI_STATE_DIR}/openbox.log"
X11VNC_LOG="${GUI_STATE_DIR}/x11vnc.log"
NOVNC_LOG="${GUI_STATE_DIR}/novnc.log"
BROWSER_LOG="${GUI_STATE_DIR}/browser.log"

export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}" || true

have_cmd() { command -v "$1" >/dev/null 2>&1; }

wait_http_ok() {
  local url="$1"
  local label="$2"
  local tries="${3:-20}"
  local delay="${4:-0.5}"
  local i

  for ((i=1; i<=tries; i++)); do
    if curl -fsS -I "$url" >/dev/null 2>&1; then
      echo "[ok] ${label}: ${url}"
      return 0
    fi
    sleep "$delay"
  done

  echo "[warn] ${label} did not become ready: ${url}" >&2
  return 1
}

wait_tcp_listen() {
  local port="$1"
  local label="$2"
  local tries="${3:-20}"
  local delay="${4:-0.5}"
  local i

  for ((i=1; i<=tries; i++)); do
    if have_cmd ss; then
      if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
        echo "[ok] ${label} listening on port ${port}"
        return 0
      fi
    else
      if curl -fsS "http://127.0.0.1:${port}/" >/dev/null 2>&1 || \
         curl -fsS -I "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
        echo "[ok] ${label} reachable on port ${port}"
        return 0
      fi
    fi
    sleep "$delay"
  done

  echo "[warn] ${label} did not start listening on port ${port}" >&2
  return 1
}

start_xvfb() {
  if pgrep -f "Xvfb ${DISPLAY}" >/dev/null 2>&1; then
    echo "[gui] Xvfb already running on ${DISPLAY}"
    return
  fi

  echo "[gui] Starting Xvfb ${DISPLAY}"
  Xvfb "${DISPLAY}" \
    -screen 0 "${SCREEN_GEOM}" \
    -ac +extension GLX +render -noreset \
    >"${XVFB_LOG}" 2>&1 &
}

start_openbox() {
  if pgrep -x openbox >/dev/null 2>&1; then
    echo "[gui] openbox already running"
    return
  fi

  echo "[gui] Starting openbox"
  openbox >"${OPENBOX_LOG}" 2>&1 &
}

start_vnc() {
  if pgrep -f "x11vnc.*${DISPLAY}.*${VNC_PORT}" >/dev/null 2>&1; then
    echo "[gui] x11vnc already running on ${VNC_PORT}"
    return
  fi

  echo "[gui] Starting x11vnc on ${VNC_PORT}"
  x11vnc \
    -display "${DISPLAY}" \
    -forever \
    -shared \
    -nopw \
    -listen 0.0.0.0 \
    -rfbport "${VNC_PORT}" \
    >"${X11VNC_LOG}" 2>&1 &
}

start_novnc() {
  if pgrep -f "websockify.*${NOVNC_PORT}" >/dev/null 2>&1; then
    echo "[gui] noVNC already running on ${NOVNC_PORT}"
    return
  fi

  echo "[gui] Starting noVNC on ${NOVNC_PORT}"
  websockify \
    --web=/usr/share/novnc/ \
    "0.0.0.0:${NOVNC_PORT}" \
    "127.0.0.1:${VNC_PORT}" \
    >"${NOVNC_LOG}" 2>&1 &
}

start_browser() {
  mkdir -p "${GUI_STATE_DIR}/browser-profile"

  if pgrep -af "google-chrome|chromium|firefox" >/dev/null 2>&1; then
    echo "[gui] Browser already running"
    return
  fi

  echo "[gui] Launching browser -> ${START_URL}"
  nohup bash -lc \
    "${BROWSER_CMD} --user-data-dir='${GUI_STATE_DIR}/browser-profile' '${START_URL}'" \
    >"${BROWSER_LOG}" 2>&1 &
}

print_status() {
  local pod_ip=""
  pod_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

  cat <<EOF

GUI READY

Local checks:
  noVNC:   http://127.0.0.1:${NOVNC_PORT}/vnc.html
  root:    http://127.0.0.1:${NOVNC_PORT}/
  VNC:     127.0.0.1:${VNC_PORT}
  app:     ${START_URL}

SSH forward then click locally:
  http://localhost:${NOVNC_PORT}/vnc.html

Suggested SSH tunnel:
  ssh -L ${NOVNC_PORT}:localhost:${NOVNC_PORT} -L ${VNC_PORT}:localhost:${VNC_PORT} root@<pod-ip>

Container display:
  ${DISPLAY}

Screen:
  ${SCREEN_GEOM}

Pod IP guess:
  ${pod_ip:-<unknown>}

Remote URLs (only work if provider exposes these ports):
  http://${pod_ip:-<pod-ip>}:${NOVNC_PORT}/vnc.html
  ${pod_ip:-<pod-ip>}:${VNC_PORT}

Logs:
  ${XVFB_LOG}
  ${OPENBOX_LOG}
  ${X11VNC_LOG}
  ${NOVNC_LOG}
  ${BROWSER_LOG}

EOF
}

# preemptively kill any existing processes that might conflict (ignore errors)
prevent_port_conflicts() {
  pkill -f "websockify.*${NOVNC_PORT}" || true
  pkill -f "x11vnc.*${VNC_PORT}" || true
  pkill -x openbox || true
  pkill -f "Xvfb ${DISPLAY}" || true
  pkill -f "google-chrome|chromium|firefox" || true
  sleep 1
}

# Sanity checks for required binaries
for bin in Xvfb openbox x11vnc websockify curl bash; do
  if ! have_cmd "$bin"; then
    echo "[err] Required command missing: $bin" >&2
    exit 1
  fi
done

prevent_port_conflicts

start_xvfb
sleep 1
start_openbox
sleep 1
start_vnc
sleep 1
start_novnc
sleep 1
start_browser

# Health checks
wait_tcp_listen "${VNC_PORT}" "x11vnc" || true
wait_http_ok "http://127.0.0.1:${NOVNC_PORT}/" "noVNC root" || true
wait_http_ok "http://127.0.0.1:${NOVNC_PORT}/vnc.html" "noVNC page" || true
wait_http_ok "${START_URL}" "target app" || true

print_status
