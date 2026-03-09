#!/usr/bin/env bash
set -euo pipefail

pkill -f "websockify.*8988" || true
pkill -f "x11vnc.*5090" || true
pkill -f xfce4-session || true
pkill -f startxfce4 || true
pkill -f "Xvfb :99" || true

echo "[desktop] Stopped"

