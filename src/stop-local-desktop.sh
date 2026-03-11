#!/usr/bin/env bash
set -euo pipefail

pkill -f "websockify.*8988|websockify.*8288|websockify.*8388" || true
pkill -f "x11vnc.*5090" || true
pkill -f "xfce4-session|startxfce4" || true
pkill -f "xfsettingsd|xfwm4|xfce4-panel|xfdesktop" || true
pkill -f "dbus-launch --exit-with-session startxfce4" || true
pkill -f "Xvfb :99" || true

echo "[desktop] Stopped local desktop processes"
