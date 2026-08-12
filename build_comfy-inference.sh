#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./build_comfy-inference.sh [options]

Build/output:
  --builder <name>        Buildx builder. Default: buildkit-scratch
  --no-push              Build/cache only; do not push or load into Docker
  --load                 Load into local Docker instead of pushing
  --platform <plats>     Default: linux/amd64
  --no-cache             Disable build cache
  --prune                Prune stopped containers and dangling Docker images
  --prune-hard           Aggressively prune cache from the selected Buildx builder
  --all-targets          Build final, browser, and desktop targets

Tagging:
  --image <repo/name>    Default: markwelshboy/comfyui-inference
  --tag <tag>            Default: latest

Target stage:
  --target <stage>       Build a specific Dockerfile stage (optional).
                         If omitted, prefer 'final' if it exists; otherwise
                         build the Dockerfile's last stage.
                         Ignored when --all-targets is used.

Metadata:
  --image-version <v>    Default: 1.0.0
  --build-date <iso>     Default: current Git commit timestamp
  --vcs-ref <sha>        Default: git rev-parse --short HEAD or "unknown"

Pass-through:
  --build-arg KEY=VALUE  Repeatable
  --dockerfile <path>    Default: Dockerfile

Examples:
  ./build_comfy-inference.sh
  ./build_comfy-inference.sh --no-push
  ./build_comfy-inference.sh --load --tag test
  ./build_comfy-inference.sh --target browser --no-push
  ./build_comfy-inference.sh --all-targets
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

IMAGE="markwelshboy/comfyui-inference"
TAG="latest"
DOCKERFILE="Dockerfile"
BUILDER="${BUILDX_BUILDER:-buildkit-scratch}"

PUSH=true
LOAD=false
PLATFORM="linux/amd64"
NO_CACHE=false
PRUNE=false
PRUNE_HARD=false
ALL_TARGETS=false
TARGET=""

IMAGE_VERSION="1.0.0"
BUILD_DATE=""
VCS_REF=""
EXTRA_BUILD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --builder) [[ -n "${2:-}" ]] || die "--builder requires a value"; BUILDER="$2"; shift 2 ;;
    --no-push) PUSH=false; shift ;;
    --load) LOAD=true; PUSH=false; shift ;;
    --platform) [[ -n "${2:-}" ]] || die "--platform requires a value"; PLATFORM="$2"; shift 2 ;;
    --no-cache) NO_CACHE=true; shift ;;
    --prune) PRUNE=true; shift ;;
    --prune-hard) PRUNE_HARD=true; shift ;;
    --all-targets) ALL_TARGETS=true; shift ;;
    --image) [[ -n "${2:-}" ]] || die "--image requires a value"; IMAGE="$2"; shift 2 ;;
    --tag) [[ -n "${2:-}" ]] || die "--tag requires a value"; TAG="$2"; shift 2 ;;
    --dockerfile) [[ -n "${2:-}" ]] || die "--dockerfile requires a path"; DOCKERFILE="$2"; shift 2 ;;
    --target) [[ -n "${2:-}" ]] || die "--target requires a stage name"; TARGET="$2"; shift 2 ;;
    --image-version) [[ -n "${2:-}" ]] || die "--image-version requires a value"; IMAGE_VERSION="$2"; shift 2 ;;
    --build-date) [[ -n "${2:-}" ]] || die "--build-date requires a value"; BUILD_DATE="$2"; shift 2 ;;
    --vcs-ref) [[ -n "${2:-}" ]] || die "--vcs-ref requires a value"; VCS_REF="$2"; shift 2 ;;
    --build-arg) [[ -n "${2:-}" ]] || die "--build-arg requires KEY=VALUE"; EXTRA_BUILD_ARGS+=(--build-arg "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

have_cmd docker || die "docker not found"
docker info >/dev/null 2>&1 || die "Docker is not accessible as the current user"
docker buildx version >/dev/null 2>&1 || die "docker buildx not available"
docker buildx inspect "${BUILDER}" >/dev/null 2>&1 || die "Buildx builder '${BUILDER}' not found or unavailable"
[[ -f "${DOCKERFILE}" ]] || die "Dockerfile not found: ${DOCKERFILE}"

if $ALL_TARGETS && [[ -n "${TARGET}" ]]; then
  die "--target cannot be used together with --all-targets"
fi

if $LOAD && [[ "${PLATFORM}" == *,* ]]; then
  die "--load supports a single platform only"
fi

# Keep metadata deterministic for a given source commit. A wall-clock build
# timestamp changes on every invocation and needlessly destroys cache reuse in
# Dockerfiles that consume BUILD_DATE.
if [[ -z "${BUILD_DATE}" ]]; then
  if have_cmd git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BUILD_DATE="$(git show -s --format=%cI HEAD 2>/dev/null || true)"
  fi
  [[ -n "${BUILD_DATE}" ]] || BUILD_DATE="unknown"
fi

if [[ -z "${VCS_REF}" ]]; then
  if have_cmd git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  else
    VCS_REF="unknown"
  fi
fi

detect_stages() {
  grep -E '^[[:space:]]*FROM[[:space:]].*[[:space:]]+AS[[:space:]]+' "${DOCKERFILE}" \
    | sed -E 's/.*[[:space:]]+AS[[:space:]]+([A-Za-z0-9_.-]+).*/\1/I' \
    | tr '\r' '\n' \
    | tr -d ' ' \
    || true
}

STAGES="$(detect_stages)"
stage_exists() { echo "${STAGES}" | grep -qx "$1"; }

if [[ -z "${TARGET}" ]] && ! $ALL_TARGETS; then
  for cand in final runtime comfy infer; do
    if stage_exists "${cand}"; then
      TARGET="${cand}"
      break
    fi
  done
fi

cat <<SUMMARY
== Build settings ==
Image       : ${IMAGE}:${TAG}
Builder     : ${BUILDER}
Platform    : ${PLATFORM}
Push        : ${PUSH}
Load        : ${LOAD}
No-cache    : ${NO_CACHE}
Prune       : ${PRUNE}
Prune-hard  : ${PRUNE_HARD}
All-targets : ${ALL_TARGETS}
Dockerfile  : ${DOCKERFILE}
Target      : ${TARGET:-<default last stage>}
Build date  : ${BUILD_DATE}
VCS ref     : ${VCS_REF}
Version     : ${IMAGE_VERSION}
SUMMARY

if $PRUNE_HARD; then
  echo "== Aggressive BuildKit cache prune: ${BUILDER} =="
  docker buildx prune --builder "${BUILDER}" --all --force || true
elif $PRUNE; then
  echo "== Safe Docker Engine prune =="
  docker container prune -f || true
  docker image prune -f || true
fi

show_usage() {
  echo "== Docker Engine usage =="
  docker system df || true
  echo
  echo "== BuildKit cache: ${BUILDER} =="
  docker buildx du --builder "${BUILDER}" || true
  echo
  echo "== Filesystems =="
  df -h / /var /srv/buildkit 2>/dev/null || df -h
}

show_usage

common_buildx_args=(
  --builder "${BUILDER}"
  -f "${DOCKERFILE}"
  --platform "${PLATFORM}"
  --build-arg "BUILD_DATE=${BUILD_DATE}"
  --build-arg "VCS_REF=${VCS_REF}"
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION}"
)

$NO_CACHE && common_buildx_args+=(--no-cache)
if $PUSH; then
  common_buildx_args+=(--push)
elif $LOAD; then
  common_buildx_args+=(--load)
fi

build_one() {
  local image_ref="$1"
  local target_stage="$2"
  local args=("${common_buildx_args[@]}")

  [[ -z "${target_stage}" ]] || args+=(--target "${target_stage}")

  echo
  echo "================================================================================"
  echo "== Building: ${image_ref}:${TAG} (target: ${target_stage:-<default last stage>})"
  echo "================================================================================"
  echo

  docker buildx build \
    -t "${image_ref}:${TAG}" \
    "${args[@]}" \
    "${EXTRA_BUILD_ARGS[@]}" \
    .
}

if $ALL_TARGETS; then
  stage_exists final   || die "Stage 'final' not found in ${DOCKERFILE}"
  stage_exists browser || die "Stage 'browser' not found in ${DOCKERFILE}"
  stage_exists desktop || die "Stage 'desktop' not found in ${DOCKERFILE}"
  build_one "${IMAGE}" "final"
  build_one "${IMAGE}-browser" "browser"
  build_one "${IMAGE}-desktop" "desktop"
else
  build_one "${IMAGE}" "${TARGET}"
fi

echo
if $PUSH; then
  echo "Build complete and pushed."
elif $LOAD; then
  echo "Build complete and loaded into local Docker."
else
  echo "Build complete; result was not pushed or loaded and remains in BuildKit cache."
fi

show_usage
