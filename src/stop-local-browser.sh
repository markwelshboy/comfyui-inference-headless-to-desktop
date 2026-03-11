#!/usr/bin/env bash
set -euo pipefail

pkill -f "websockify.*8988" || true
pkill -f "x11vnc.*5090" || true
pkill -x openbox || true
pkill -f "Xvfb :99" || true
pkill -f "google-chrome|chromium|firefox" || true

echo "[gui] Stopped local browser GUI processes"
