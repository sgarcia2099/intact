#!/usr/bin/env bash

set -euo pipefail

INPUT_FILE=""
FEATURES_FILE=""
SPEC_MS1_FILE=""
LOG_FILE=""

usage() {
  cat <<'EOF'
Usage:
  run_flashdeconv.sh --input <file.mzML> --features <features.tsv> --spec-ms1 <spec.tsv> --log <log-file>
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_FILE=${2:-}
      shift 2
      ;;
    --features)
      FEATURES_FILE=${2:-}
      shift 2
      ;;
    --spec-ms1)
      SPEC_MS1_FILE=${2:-}
      shift 2
      ;;
    --log)
      LOG_FILE=${2:-}
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${INPUT_FILE}" ]] || fail "--input is required"
[[ -n "${FEATURES_FILE}" ]] || fail "--features is required"
[[ -n "${SPEC_MS1_FILE}" ]] || fail "--spec-ms1 is required"
[[ -n "${LOG_FILE}" ]] || fail "--log is required"
[[ -f "${INPUT_FILE}" ]] || fail "Input mzML not found: ${INPUT_FILE}"

command -v docker >/dev/null 2>&1 || fail "docker is required"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
DEFAULT_CONFIG_FILE="${ROOT_DIR}/config/pipeline.env.example"
LOCAL_CONFIG_FILE="${ROOT_DIR}/config/pipeline.env"

# Preserve explicit runtime overrides so config files do not clobber them.
OPENMS_IMAGE_ENV_OVERRIDE="${OPENMS_IMAGE-}"
OPENMS_IMAGE_ENV_SET=0
if [[ -n "${OPENMS_IMAGE+x}" ]]; then
  OPENMS_IMAGE_ENV_SET=1
fi

OPENMS_DOCKER_PLATFORM_ENV_OVERRIDE="${OPENMS_DOCKER_PLATFORM-}"
OPENMS_DOCKER_PLATFORM_ENV_SET=0
if [[ -n "${OPENMS_DOCKER_PLATFORM+x}" ]]; then
  OPENMS_DOCKER_PLATFORM_ENV_SET=1
fi

if [[ -f "${DEFAULT_CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${DEFAULT_CONFIG_FILE}"
fi

if [[ -f "${LOCAL_CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${LOCAL_CONFIG_FILE}"
fi

if [[ ${OPENMS_IMAGE_ENV_SET} -eq 1 ]]; then
  OPENMS_IMAGE="${OPENMS_IMAGE_ENV_OVERRIDE}"
fi
if [[ ${OPENMS_DOCKER_PLATFORM_ENV_SET} -eq 1 ]]; then
  OPENMS_DOCKER_PLATFORM="${OPENMS_DOCKER_PLATFORM_ENV_OVERRIDE}"
fi

FLASHDECONV_INI=${FLASHDECONV_INI:-"${ROOT_DIR}/config/flashdeconv.ini"}
OPENMS_DOCKER_PLATFORM=${OPENMS_DOCKER_PLATFORM:-""}

[[ -f "${FLASHDECONV_INI}" ]] || fail "FLASHDeconv INI not found: ${FLASHDECONV_INI}"

mkdir -p "$(dirname "${FEATURES_FILE}")" "$(dirname "${SPEC_MS1_FILE}")" "$(dirname "${LOG_FILE}")"

input_dir=$(cd "$(dirname "${INPUT_FILE}")" && pwd)
input_name=$(basename "${INPUT_FILE}")
output_dir=$(cd "$(dirname "${FEATURES_FILE}")" && pwd)
features_name=$(basename "${FEATURES_FILE}")
spec_ms1_name=$(basename "${SPEC_MS1_FILE}")
ini_dir=$(cd "$(dirname "${FLASHDECONV_INI}")" && pwd)
ini_name=$(basename "${FLASHDECONV_INI}")

docker_cmd=(
  docker run --rm
  -v "${input_dir}:/input"
  -v "${output_dir}:/output"
  -v "${ini_dir}:/config"
  -u "$(id -u):$(id -g)"
)

if [[ -n "${OPENMS_DOCKER_PLATFORM}" ]]; then
  docker_cmd+=(--platform "${OPENMS_DOCKER_PLATFORM}")
fi

docker_cmd_args=(
  -in "/input/${input_name}"
  -out "/output/${features_name}"
  -out_spec1 "/output/${spec_ms1_name}"
  -ini "/config/${ini_name}"
  -threads "${FLASHDECONV_THREADS}"
)

docker_cmd_explicit=(
  "${docker_cmd[@]}"
  "${OPENMS_IMAGE}"
  /opt/OpenMS/bin/FLASHDeconv
  "${docker_cmd_args[@]}"
)

if ! "${docker_cmd_explicit[@]}" >"${LOG_FILE}" 2>&1; then
  # Some custom images set ENTRYPOINT to FLASHDeconv. In that case,
  # passing /opt/OpenMS/bin/FLASHDeconv again causes a trailing-argument error.
  if grep -q "Trailing text argument(s) '\[/opt/OpenMS/bin/FLASHDeconv\]' given" "${LOG_FILE}"; then
    docker_cmd_entrypoint=(
      "${docker_cmd[@]}"
      "${OPENMS_IMAGE}"
      "${docker_cmd_args[@]}"
    )
    "${docker_cmd_entrypoint[@]}" >"${LOG_FILE}" 2>&1 || true
  fi
fi

[[ -f "${FEATURES_FILE}" ]] || fail "Expected FLASHDeconv feature output was not created: ${FEATURES_FILE}"