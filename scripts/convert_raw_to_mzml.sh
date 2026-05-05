#!/usr/bin/env bash

set -euo pipefail

INPUT_FILE=""
OUTPUT_FILE=""
LOG_FILE=""

usage() {
  cat <<'EOF'
Usage:
  convert_raw_to_mzml.sh --input <file.raw> --output <file.mzML> --log <log-file>
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
    --output)
      OUTPUT_FILE=${2:-}
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
[[ -n "${OUTPUT_FILE}" ]] || fail "--output is required"
[[ -n "${LOG_FILE}" ]] || fail "--log is required"
[[ -f "${INPUT_FILE}" ]] || fail "Input RAW file not found: ${INPUT_FILE}"

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

PWIZ_DOCKER_SECURITY_OPT=${PWIZ_DOCKER_SECURITY_OPT:-seccomp=unconfined}

mkdir -p "$(dirname "${OUTPUT_FILE}")" "$(dirname "${LOG_FILE}")"

input_dir=$(cd "$(dirname "${INPUT_FILE}")" && pwd)
input_name=$(basename "${INPUT_FILE}")
output_dir=$(cd "$(dirname "${OUTPUT_FILE}")" && pwd)
output_name=$(basename "${OUTPUT_FILE}")
base_name=${output_name%.mzML}
host_uid=$(id -u)
host_gid=$(id -g)

peak_filter="peakPicking ${MSCONVERT_PEAK_PICKING:-vendor} msLevel=1-"

compression_flag=()
if [[ "${MSCONVERT_COMPRESSION:-zlib}" == "zlib" ]]; then
  compression_flag=(--zlib)
fi

encoding_flag=()
if [[ "${MSCONVERT_BINARY_ENCODING:-32}" == "32" ]]; then
  encoding_flag=(--32)
else
  encoding_flag=(--64)
fi

extra_filter_args=()
if [[ -n "${MSCONVERT_EXTRA_FILTERS:-}" ]]; then
  extra_filter_args=(--filter "${MSCONVERT_EXTRA_FILTERS}")
fi

security_opts=()
if [[ -n "${PWIZ_DOCKER_SECURITY_OPT}" ]]; then
  security_opts=(--security-opt "${PWIZ_DOCKER_SECURITY_OPT}")
fi

# Run as root inside the container so Wine can use the pre-configured /wineprefix64.
# After conversion, chown the output file back to the host user so subsequent pipeline
# steps (which run as the host user) can read and move it without sudo.
docker run --rm \
  "${security_opts[@]}" \
  -v "${input_dir}:/input:ro" \
  -v "${output_dir}:/output" \
  "${PWIZ_IMAGE}" \
  sh -c "
    wine msconvert \
      \"/input/${input_name}\" \
      --mzML \
      --outfile \"${base_name}.mzML\" \
      --outdir /output \
      ${encoding_flag[*]} \
      ${compression_flag[*]} \
      --filter \"${peak_filter}\" \
      ${extra_filter_args[*]} \
    && chown ${host_uid}:${host_gid} \"/output/${base_name}.mzML\"
  " \
  >"${LOG_FILE}" 2>&1

[[ -f "${OUTPUT_FILE}" ]] || fail "Expected mzML output was not created: ${OUTPUT_FILE}"