#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/../.." && pwd)

DOCKER_REPO="${DOCKER_REPO:-}"  # e.g. myuser/intact-openms-flashdeconv
OPENMS_VERSION="${OPENMS_VERSION:-3.4.1}"
OPENMS_REF="${OPENMS_REF:-}"
PLATFORM="${PLATFORM:-linux/amd64}"
BASE_IMAGE=""
BUILD_MODE="${BUILD_MODE:-prebuilt}"
PUSH=0
TAG_STABLE=0

usage() {
  cat <<'EOF'
Usage:
  docker/openms-stable/build.sh --repo <dockerhub-user/repo> [options]

Options:
  --repo <name>             Docker image repo, e.g. myuser/intact-openms-flashdeconv
  --openms-version <ver>    OpenMS stable version tag (default: 3.4.1)
  --openms-ref <ref>        Source ref for source-amd64 mode (e.g. release/3.5.0)
  --build-mode <mode>       prebuilt (default) or source-amd64
  --base-image <image>      Explicit OpenMS base image (overrides --openms-version)
  --platform <platform>     Build platform (default: linux/amd64)
  --push                    Push tags to Docker Hub (requires docker login)
  --tag-stable              Also tag/push :stable
  --help                    Show this help

Examples:
  docker/openms-stable/build.sh \
    --repo myuser/intact-openms-flashdeconv \
    --openms-version 3.4.1

  docker/openms-stable/build.sh \
    --repo myuser/intact-openms-flashdeconv \
    --openms-version 3.4.1 \
    --push --tag-stable

  docker/openms-stable/build.sh \
    --repo myuser/intact-openms-flashdeconv \
    --openms-version 3.5.0 \
    --platform linux/arm64 \
    --push

  docker/openms-stable/build.sh \
    --repo myuser/intact-openms-flashdeconv \
    --openms-version 3.5.0 \
    --build-mode source-amd64 \
    --push
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      DOCKER_REPO=${2:-}
      shift 2
      ;;
    --openms-version)
      OPENMS_VERSION=${2:-}
      shift 2
      ;;
    --openms-ref)
      OPENMS_REF=${2:-}
      shift 2
      ;;
    --build-mode)
      BUILD_MODE=${2:-}
      shift 2
      ;;
    --base-image)
      BASE_IMAGE=${2:-}
      shift 2
      ;;
    --platform)
      PLATFORM=${2:-}
      shift 2
      ;;
    --push)
      PUSH=1
      shift
      ;;
    --tag-stable)
      TAG_STABLE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -n "${DOCKER_REPO}" ]] || { echo "--repo is required" >&2; exit 1; }

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

if [[ "${BUILD_MODE}" != "prebuilt" && "${BUILD_MODE}" != "source-amd64" ]]; then
  echo "--build-mode must be one of: prebuilt, source-amd64" >&2
  exit 1
fi

dockerfile_path="${SCRIPT_DIR}/Dockerfile"
tag_suffix=""

if [[ "${BUILD_MODE}" == "source-amd64" ]]; then
  dockerfile_path="${SCRIPT_DIR}/Dockerfile.source-amd64"
  PLATFORM="linux/amd64"
  tag_suffix="-amd64"
  if [[ -z "${OPENMS_REF}" ]]; then
    OPENMS_REF="release/${OPENMS_VERSION}"
  fi
fi

if [[ -z "${BASE_IMAGE}" ]]; then
  BASE_IMAGE="ghcr.io/openms/openms-executables:${OPENMS_VERSION}"
fi

if [[ "${BUILD_MODE}" == "prebuilt" ]]; then
  manifest_json=$(docker manifest inspect "${BASE_IMAGE}" 2>/dev/null || true)
  if [[ -z "${manifest_json}" ]]; then
    echo "Could not inspect base image manifest: ${BASE_IMAGE}" >&2
    exit 1
  fi

  if command -v jq >/dev/null 2>&1; then
    req_os=${PLATFORM%%/*}
    req_arch_part=${PLATFORM#*/}
    req_arch=${req_arch_part%%/*}
    if ! echo "${manifest_json}" | jq -e --arg os "${req_os}" --arg arch "${req_arch}" '.manifests[]?.platform | select(.os == $os and .architecture == $arch)' >/dev/null; then
      echo "Base image ${BASE_IMAGE} does not provide ${PLATFORM}." >&2
      echo "Available platforms:" >&2
      echo "${manifest_json}" | jq -r '.manifests[]?.platform | "  - \(.os)/\(.architecture)"' >&2
      echo "Tip: try --platform linux/arm64, use --build-mode source-amd64, or choose a different --base-image tag." >&2
      exit 1
    fi
  fi
fi

major_minor=$(echo "${OPENMS_VERSION}" | awk -F'.' '{print $1 "." $2}')
image_tag_full="${DOCKER_REPO}:openms-${OPENMS_VERSION}${tag_suffix}"
image_tag_minor="${DOCKER_REPO}:openms-${major_minor}${tag_suffix}"

build_args=(
  --build-arg "OPENMS_VERSION=${OPENMS_VERSION}"
  --build-arg "OPENMS_BASE_IMAGE=${BASE_IMAGE}"
  --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  --build-arg "VCS_REF=$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
)

if [[ -n "${OPENMS_REF}" ]]; then
  build_args+=(--build-arg "OPENMS_REF=${OPENMS_REF}")
fi

tags=(
  -t "${image_tag_full}"
  -t "${image_tag_minor}"
)

if [[ ${TAG_STABLE} -eq 1 ]]; then
  tags+=( -t "${DOCKER_REPO}:stable" )
fi

push_args=(--load)
if [[ ${PUSH} -eq 1 ]]; then
  push_args=(--push)
fi

echo "Building ${image_tag_full} (platform=${PLATFORM})"
docker buildx build \
  --platform "${PLATFORM}" \
  "${build_args[@]}" \
  "${tags[@]}" \
  -f "${dockerfile_path}" \
  "${push_args[@]}" \
  "${ROOT_DIR}"

# Runtime sanity check for local builds.
if [[ ${PUSH} -eq 0 ]]; then
  host_arch=$(uname -m)
  case "${host_arch}" in
    x86_64) host_arch=amd64 ;;
    aarch64|arm64) host_arch=arm64 ;;
  esac
  target_arch=${PLATFORM#*/}
  target_arch=${target_arch%%/*}

  if [[ "${host_arch}" == "${target_arch}" ]]; then
    echo "Running sanity check for ${image_tag_full}"
    docker run --rm "${image_tag_full}" --help | head -n 20
  else
    echo "Skipping local sanity check: host arch ${host_arch} differs from target ${target_arch}"
  fi
fi

echo "Done."
