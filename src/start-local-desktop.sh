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
XFCE_LOG="${GUI_STATE_DIR}/xfce.log"
X11VNC_LOG="${GUI_STATE_DIR}/x11vnc.log"
NOVNC_LOG="${GUI_STATE_DIR}/novnc.log"

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
  Xvfb "${DISPLAY}" -screen 0 "${SCREEN_GEOM}" -ac +extension GLX +render -noreset \
    >"${XVFB_LOG}" 2>&1 &
  sleep 1
}

start_xfce() {
  if pgrep -f xfce4-session >/dev/null 2>&1; then
    return
  fi
  dbus-launch --exit-with-session startxfce4 >"${XFCE_LOG}" 2>&1 &
  sleep 2
}

start_x11vnc() {
  if pgrep -f "x11vnc.*${DISPLAY}" >/dev/null 2>&1; then
    return
  fi
  x11vnc \
    -display "${DISPLAY}" \
    -forever \
    -shared \
    -nopw \
    -rfbport "${VNC_PORT}" \
    >"${X11VNC_LOG}" 2>&1 &
  sleep 1
}

start_novnc() {
  if pgrep -f "websockify.*${NOVNC_PORT}" >/dev/null 2>&1; then
    return
  fi
  websockify --web=/usr/share/novnc/ "${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" \
    >"${NOVNC_LOG}" 2>&1 &
  sleep 1
}

start_xvfb
start_xfce
start_x11vnc
start_novnc

cat <<EOF
[desktop] Ready

[desktop] noVNC:
[desktop]   http://<host-or-pod-ip>:${NOVNC_PORT}/vnc.html

[desktop] Raw VNC:
[desktop]   <host-or-pod-ip>:${VNC_PORT}

[desktop] Display:
[desktop]   ${DISPLAY}
EOF

