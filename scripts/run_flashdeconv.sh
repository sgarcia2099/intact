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

if [[ -f "${DEFAULT_CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${DEFAULT_CONFIG_FILE}"
fi

if [[ -f "${LOCAL_CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${LOCAL_CONFIG_FILE}"
fi

FLASHDECONV_INI=${FLASHDECONV_INI:-"${ROOT_DIR}/config/flashdeconv.ini"}

[[ -f "${FLASHDECONV_INI}" ]] || fail "FLASHDeconv INI not found: ${FLASHDECONV_INI}"

mkdir -p "$(dirname "${FEATURES_FILE}")" "$(dirname "${SPEC_MS1_FILE}")" "$(dirname "${LOG_FILE}")"

input_dir=$(cd "$(dirname "${INPUT_FILE}")" && pwd)
input_name=$(basename "${INPUT_FILE}")
output_dir=$(cd "$(dirname "${FEATURES_FILE}")" && pwd)
features_name=$(basename "${FEATURES_FILE}")
spec_ms1_name=$(basename "${SPEC_MS1_FILE}")
ini_dir=$(cd "$(dirname "${FLASHDECONV_INI}")" && pwd)
ini_name=$(basename "${FLASHDECONV_INI}")

docker run --rm \
  -v "${input_dir}:/input" \
  -v "${output_dir}:/output" \
  -v "${ini_dir}:/config" \
  -u "$(id -u):$(id -g)" \
  "${OPENMS_IMAGE}" \
  /opt/OpenMS/bin/FLASHDeconv \
  -in "/input/${input_name}" \
  -out "/output/${features_name}" \
  -out_spec1 "/output/${spec_ms1_name}" \
  -ini "/config/${ini_name}" \
  -threads "${FLASHDECONV_THREADS}" \
  >"${LOG_FILE}" 2>&1

[[ -f "${FEATURES_FILE}" ]] || fail "Expected FLASHDeconv feature output was not created: ${FEATURES_FILE}"