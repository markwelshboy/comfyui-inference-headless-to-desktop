#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"

SCREEN_GEOM="${SCREEN_GEOM:-1440x900x24}"
NOVNC_PORT="${NOVNC_PORT:-8988}"
VNC_PORT="${VNC_PORT:-5090}"
START_URL="${START_URL:-http://127.0.0.1:8188}"

GUI_STATE_DIR="${GUI_STATE_DIR:-/tmp/local-gui}"
mkdir -p "${GUI_STATE_DIR}" /tmp/.X11-unix

XVFB_LOG="${GUI_STATE_DIR}/xvfb.log"
OPENBOX_LOG="${GUI_STATE_DIR}/openbox.log"
X11VNC_LOG="${GUI_STATE_DIR}/x11vnc.log"
NOVNC_LOG="${GUI_STATE_DIR}/novnc.log"
BROWSER_LOG="${GUI_STATE_DIR}/browser.log"

# CPU rendering only
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-runtime}"
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 700 "${XDG_RUNTIME_DIR}" || true

start_xvfb() {

  if pgrep -f "Xvfb ${DISPLAY}" >/dev/null 2>&1; then
      return
  fi

  echo "[gui] Starting Xvfb ${DISPLAY}"

  Xvfb "${DISPLAY}" \
      -screen 0 "${SCREEN_GEOM}" \
      -ac +extension GLX +render -noreset \
      >"${XVFB_LOG}" 2>&1 &

  sleep 1
}

start_openbox() {

  if pgrep -x openbox >/dev/null 2>&1; then
      return
  fi

  echo "[gui] Starting openbox"

  openbox >"${OPENBOX_LOG}" 2>&1 &
}

start_vnc() {

  if pgrep -f "x11vnc.*${DISPLAY}" >/dev/null 2>&1; then
      return
  fi

  echo "[gui] Starting x11vnc on ${VNC_PORT}"

  x11vnc \
      -display "${DISPLAY}" \
      -forever \
      -shared \
      -nopw \
      -rfbport "${VNC_PORT}" \
      >"${X11VNC_LOG}" 2>&1 &
}

start_novnc() {

  if pgrep -f "websockify.*${NOVNC_PORT}" >/dev/null 2>&1; then
      return
  fi

  echo "[gui] Starting noVNC on ${NOVNC_PORT}"

  websockify \
      --web=/usr/share/novnc/ \
      "${NOVNC_PORT}" \
      "127.0.0.1:${VNC_PORT}" \
      >"${NOVNC_LOG}" 2>&1 &
}

start_browser() {

  if pgrep -a firefox >/dev/null 2>&1; then
      return
  fi

  mkdir -p "${GUI_STATE_DIR}/firefox-profile"

  echo "[gui] Launching Firefox"

  firefox \
      --no-remote \
      --profile "${GUI_STATE_DIR}/firefox-profile" \
      "${START_URL}" \
      >"${BROWSER_LOG}" 2>&1 &
}

start_xvfb
start_openbox
start_vnc
start_novnc
start_browser

cat <<EOF

GUI READY

Open in browser:

http://<pod-ip>:8988/vnc.html

Raw VNC (optional):
<host>:5090

Display:
${DISPLAY}

Start URL:
${START_URL}

EOF
