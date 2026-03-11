#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"

SCREEN_GEOM="${SCREEN_GEOM:-1440x900x24}"
NOVNC_PORT="${NOVNC_PORT:-8988}"
VNC_PORT="${VNC_PORT:-5090}"

GUI_STATE_DIR="${GUI_STATE_DIR:-/tmp/local-desktop}"
mkdir -p "${GUI_STATE_DIR}" /tmp/.X11-unix

XVFB_LOG="${GUI_STATE_DIR}/xvfb.log"
DESKTOP_LOG="${GUI_STATE_DIR}/desktop.log"
X11VNC_LOG="${GUI_STATE_DIR}/x11vnc.log"
NOVNC_LOG="${GUI_STATE_DIR}/novnc.log"

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
    echo "[desktop] Xvfb already running on ${DISPLAY}"
    return
  fi

  echo "[desktop] Starting Xvfb ${DISPLAY}"
  Xvfb "${DISPLAY}" \
    -screen 0 "${SCREEN_GEOM}" \
    -ac +extension GLX +render -noreset \
    >"${XVFB_LOG}" 2>&1 &
}

start_desktop() {
  if pgrep -f "xfce4-session|startxfce4" >/dev/null 2>&1; then
    echo "[desktop] Xfce session already running"
    return
  fi

  echo "[desktop] Starting Xfce session"
  nohup dbus-launch --exit-with-session startxfce4 \
    >"${DESKTOP_LOG}" 2>&1 &
}

start_vnc() {
  if pgrep -f "x11vnc.*${DISPLAY}.*${VNC_PORT}" >/dev/null 2>&1; then
    echo "[desktop] x11vnc already running on ${VNC_PORT}"
    return
  fi

  echo "[desktop] Starting x11vnc on ${VNC_PORT}"
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
    echo "[desktop] noVNC already running on ${NOVNC_PORT}"
    return
  fi

  echo "[desktop] Starting noVNC on ${NOVNC_PORT}"
  websockify \
    --web=/usr/share/novnc/ \
    "0.0.0.0:${NOVNC_PORT}" \
    "127.0.0.1:${VNC_PORT}" \
    >"${NOVNC_LOG}" 2>&1 &
}

print_status() {
  local pod_ip=""
  pod_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

  cat <<EOF

DESKTOP READY

Local checks:
  noVNC:   http://127.0.0.1:${NOVNC_PORT}/vnc.html
  root:    http://127.0.0.1:${NOVNC_PORT}/
  VNC:     127.0.0.1:${VNC_PORT}

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
  ${DESKTOP_LOG}
  ${X11VNC_LOG}
  ${NOVNC_LOG}

EOF
}

for bin in Xvfb x11vnc websockify curl bash dbus-launch startxfce4; do
  if ! have_cmd "$bin"; then
    echo "[err] Required command missing: $bin" >&2
    exit 1
  fi
done

start_xvfb
sleep 1
start_desktop
sleep 2
start_vnc
sleep 1
start_novnc

wait_tcp_listen "${VNC_PORT}" "x11vnc" || true
wait_http_ok "http://127.0.0.1:${NOVNC_PORT}/" "noVNC root" || true
wait_http_ok "http://127.0.0.1:${NOVNC_PORT}/vnc.html" "noVNC page" || true

print_status
