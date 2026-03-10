# syntax=docker/dockerfile:1.7

FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04 AS runtime-base

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_INPUT=1 \
    PIP_PREFER_BINARY=1 \
    VENV=/opt/venv

# ---- OS + Python 3.12 + core tooling ----
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev \
      git git-lfs curl ca-certificates jq \
      build-essential gcc g++ cmake ninja-build pkg-config \
      ffmpeg aria2 rsync tmux unzip wget vim less nano \
      libgl1 libglib2.0-0 \
      gcc-12 g++-12 \
      openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /var/run/sshd /workspace \
    && git lfs install --system \
    && python3.12 -m venv "${VENV}"

ENV PATH="${VENV}/bin:${PATH}"

# ---- pip tooling ----
# Upgrade pip/setuptools/wheel to latest compatible versions to avoid old versions that don't understand the new metadata formats
# Note that we have to do this before installing any packages, otherwise old pip/setuptools may install older versions of 
# packages that then conflict with the newer pip/setuptools.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -U "pip<25.2" "setuptools>=66.1,<82" "wheel>=0.38"

# ---- Constraints ----
COPY pip.conf /etc/pip.conf
COPY constraints.txt /opt/constraints.txt
ENV PIP_CONSTRAINT=/opt/constraints.txt
ENV PIP_BUILD_CONSTRAINT=/opt/constraints.txt

# ---- Torch stack FIRST (pinned, cu128 nightly) ----
ARG TORCH_INDEX="https://download.pytorch.org/whl/nightly/cu128"
ARG TORCH_VER="2.12.0.dev20260308+cu128"
ARG TORCHVISION_VER="0.26.0.dev20260308+cu128"
ARG TORCHAUDIO_VER="2.11.0.dev20260308+cu128"

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir \
      --index-url "${TORCH_INDEX}" \
      "torch==${TORCH_VER}" \
      "torchvision==${TORCHVISION_VER}" \
      "torchaudio==${TORCHAUDIO_VER}"

# ---- Base Python runtime libs ----
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir \
      huggingface_hub==0.36.0 \
      pyyaml tqdm pillow \
      opencv-python-headless==4.12.0.88

# ---- ComfyUI clone ----
ARG COMFYUI_REF="v0.9.2"
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI \
    && cd /workspace/ComfyUI \
    && git checkout "${COMFYUI_REF}"

WORKDIR /workspace/ComfyUI

# Strip torch/torchvision/torchaudio from ComfyUI requirements
RUN python - <<'PY'
import re, pathlib

src = pathlib.Path("requirements.txt")
dst = pathlib.Path("/tmp/requirements.notorch.txt")

out = []
for line in src.read_text().splitlines():
    s = line.strip()
    if not s or s.startswith("#"):
        out.append(line)
        continue
    if re.match(r"^(torch|torchvision|torchaudio)(\b|==|>=|<=|~=|!=|<|>)", s):
        continue
    out.append(line)

dst.write_text("\n".join(out) + "\n")
print(f"Wrote {dst} (removed torch/vision/audio)")
PY

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir -c /opt/constraints.txt -r /tmp/requirements.notorch.txt

# Copy the upscaler
COPY 4xLSDIR.pth /

# Thin startup wrapper
COPY src/start_script.sh /start_script.sh
RUN chmod +x /start_script.sh

# -------------------------------------------------------------------
# Headless target
# -------------------------------------------------------------------
FROM runtime-base AS final

EXPOSE 22 8188 8288 8388 8888
ENTRYPOINT ["/start_script.sh"]

# -------------------------------------------------------------------
# Browser target: Firefox + VNC/noVNC
# -------------------------------------------------------------------
FROM runtime-base AS browser

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      xvfb \
      openbox \
      x11vnc \
      novnc \
      websockify \
      firefox \
      dbus-x11 \
      xauth \
      mesa-utils \
      libgl1-mesa-dri \
    && rm -rf /var/lib/apt/lists/*

COPY src/start-local-browser.sh /usr/local/bin/start-local-browser
COPY src/stop-local-browser.sh /usr/local/bin/stop-local-browser
RUN chmod +x /usr/local/bin/start-local-browser /usr/local/bin/stop-local-browser

EXPOSE 22 8188 8288 8388 8888 8988 5090
ENTRYPOINT ["/start_script.sh"]

# -------------------------------------------------------------------
# Desktop target: browser + minimal Xfce
# -------------------------------------------------------------------
FROM browser AS desktop

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      xfce4-panel \
      xfce4-session \
      xfce4-settings \
      xfce4-terminal \
      xfce4-appfinder \
      xfwm4 \
      thunar \
      thunar-archive-plugin \
      xfdesktop4 \
      xfce4-taskmanager \
      tango-icon-theme \
      dbus-x11 \
    && rm -rf /var/lib/apt/lists/*

COPY src/start-local-desktop.sh /usr/local/bin/start-local-desktop
COPY src/stop-local-desktop.sh /usr/local/bin/stop-local-desktop
RUN chmod +x /usr/local/bin/start-local-desktop /usr/local/bin/stop-local-desktop

EXPOSE 22 8188 8288 8388 8888 8988 5090
ENTRYPOINT ["/start_script.sh"]

