#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=${SCRIPT_DIR}
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

INPUT_PATH=""
OUTPUT_DIR=""
SAMPLE_NAME=""
BATCH_MODE=0
RUN_FILTER=0
DRY_RUN=0
KEEP_INTERMEDIATE=${KEEP_INTERMEDIATE:-1}
CONTINUE_ON_ERROR=${CONTINUE_ON_ERROR:-1}
BATCH_TOTAL=0
BATCH_FAILED=0
BATCH_SUCCEEDED=0

usage() {
  cat <<'EOF'
Usage:
  ./pipeline.sh --input <raw-file-or-directory> --output <output-dir> [options]

Options:
  --input <path>         Input Thermo .raw file or directory containing .raw files
  --output <path>        Output directory for mzML, FLASHDeconv, tables, and logs
  --sample <name>        Sample name override for single-file mode
  --batch                Treat input as a directory and process every .raw file found
  --filter               Run optional R-based filtering after table normalization
  --dry-run              Print commands without executing them
  --help                 Show this help message

Environment/config overrides:
  PWIZ_IMAGE, OPENMS_IMAGE, FLASHDECONV_INI, MSCONVERT_PEAK_PICKING,
  FLASHDECONV_THREADS, FILTER_PPM, FILTER_RT_MINUTES, FILTER_MIN_INTENSITY,
  KEEP_INTERMEDIATE, CONTINUE_ON_ERROR
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_file() {
  local path=$1
  [[ -f "${path}" ]] || fail "Required file not found: ${path}"
}

require_dir() {
  local path=$1
  [[ -d "${path}" ]] || fail "Required directory not found: ${path}"
}

abs_path() {
  local path=$1
  if [[ -d "${path}" ]]; then
    (cd "${path}" && pwd)
  else
    (cd "$(dirname "${path}")" && printf '%s/%s\n' "$(pwd)" "$(basename "${path}")")
  fi
}

run_or_echo() {
  if [[ ${DRY_RUN} -eq 1 ]]; then
    printf 'DRY_RUN: '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --input)
        INPUT_PATH=${2:-}
        shift 2
        ;;
      --output)
        OUTPUT_DIR=${2:-}
        shift 2
        ;;
      --sample)
        SAMPLE_NAME=${2:-}
        shift 2
        ;;
      --batch)
        BATCH_MODE=1
        shift
        ;;
      --filter)
        RUN_FILTER=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
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

  [[ -n "${INPUT_PATH}" ]] || fail "--input is required"
  [[ -n "${OUTPUT_DIR}" ]] || fail "--output is required"
}

prepare_dirs() {
  mkdir -p "${OUTPUT_DIR}" \
    "${OUTPUT_DIR}/mzml" \
    "${OUTPUT_DIR}/flashdeconv" \
    "${OUTPUT_DIR}/tables" \
    "${OUTPUT_DIR}/logs"
}

check_prereqs() {
  if [[ ${DRY_RUN} -ne 1 ]]; then
    command -v docker >/dev/null 2>&1 || fail "docker is required"
    if [[ ${RUN_FILTER} -eq 1 ]]; then
      command -v Rscript >/dev/null 2>&1 || fail "Rscript is required when --filter is enabled"
    fi
  fi

  require_file "${ROOT_DIR}/scripts/convert_raw_to_mzml.sh"
  require_file "${ROOT_DIR}/scripts/run_flashdeconv.sh"
  require_file "${ROOT_DIR}/scripts/normalize_flashdeconv_output.sh"
  require_file "${FLASHDECONV_INI}"
}

process_sample() {
  local raw_file=$1
  local sample_id=$2
  local raw_abs
  local output_abs
  local sample_log_dir
  local mzml_file
  local features_tsv
  local spec_ms1_tsv
  local normalized_tsv
  local filtered_tsv

  raw_abs=$(abs_path "${raw_file}")
  output_abs=$(abs_path "${OUTPUT_DIR}")
  sample_log_dir="${output_abs}/logs/${sample_id}"
  mzml_file="${output_abs}/mzml/${sample_id}.mzML"
  features_tsv="${output_abs}/flashdeconv/${sample_id}_features.tsv"
  spec_ms1_tsv="${output_abs}/flashdeconv/${sample_id}_spec_ms1.tsv"
  normalized_tsv="${output_abs}/tables/${sample_id}_neutral_masses.tsv"
  filtered_tsv="${output_abs}/tables/${sample_id}_neutral_masses.filtered.tsv"

  mkdir -p "${sample_log_dir}"
  log "Processing ${sample_id} from ${raw_abs}"

  if ! run_or_echo "${ROOT_DIR}/scripts/convert_raw_to_mzml.sh" \
    --input "${raw_abs}" \
    --output "${mzml_file}" \
    --log "${sample_log_dir}/msconvert.log"; then
    log "Conversion failed for ${sample_id}; see ${sample_log_dir}/msconvert.log"
    return 1
  fi

  if ! run_or_echo "${ROOT_DIR}/scripts/run_flashdeconv.sh" \
    --input "${mzml_file}" \
    --features "${features_tsv}" \
    --spec-ms1 "${spec_ms1_tsv}" \
    --log "${sample_log_dir}/flashdeconv.log"; then
    log "FLASHDeconv failed for ${sample_id}; see ${sample_log_dir}/flashdeconv.log"
    return 1
  fi

  if ! run_or_echo "${ROOT_DIR}/scripts/normalize_flashdeconv_output.sh" \
    --features "${features_tsv}" \
    --sample "${sample_id}" \
    --source "${mzml_file}" \
    --output "${normalized_tsv}"; then
    log "Normalization failed for ${sample_id}"
    return 1
  fi

  if [[ ${RUN_FILTER} -eq 1 ]]; then
    if ! run_or_echo Rscript "${ROOT_DIR}/scripts/filter_neutral_masses.R" \
      --input "${normalized_tsv}" \
      --output "${filtered_tsv}" \
      --ppm "${FILTER_PPM}" \
      --rt-window "${FILTER_RT_MINUTES}" \
      --min-intensity "${FILTER_MIN_INTENSITY}" \
      --min-qscore "${FILTER_MIN_QSCORE:-0}"; then
      log "Filtering failed for ${sample_id}"
      return 1
    fi
  fi

  if [[ ${KEEP_INTERMEDIATE} -eq 0 && ${DRY_RUN} -eq 0 ]]; then
    rm -f "${spec_ms1_tsv}"
  fi
}

process_batch() {
  local input_abs
  local status=0
  local raw_file
  local sample_id

  BATCH_TOTAL=0
  BATCH_FAILED=0
  BATCH_SUCCEEDED=0

  input_abs=$(abs_path "${INPUT_PATH}")
  require_dir "${input_abs}"

  while IFS= read -r -d '' raw_file; do
    BATCH_TOTAL=$((BATCH_TOTAL + 1))
    sample_id=$(basename "${raw_file}")
    sample_id=${sample_id%.raw}
    sample_id=${sample_id%.RAW}

    if ! process_sample "${raw_file}" "${sample_id}"; then
      status=1
      BATCH_FAILED=$((BATCH_FAILED + 1))
      log "Sample failed: ${sample_id}"
      if [[ ${CONTINUE_ON_ERROR} -ne 1 ]]; then
        break
      fi
    else
      BATCH_SUCCEEDED=$((BATCH_SUCCEEDED + 1))
    fi
  done < <(find "${input_abs}" -maxdepth 1 \( -name '*.raw' -o -name '*.RAW' \) -print0 | sort -z)

  [[ ${BATCH_TOTAL} -gt 0 ]] || fail "No .raw files found in ${input_abs}"

  log "Batch summary: total=${BATCH_TOTAL}, succeeded=${BATCH_SUCCEEDED}, failed=${BATCH_FAILED}"
  return ${status}
}

main() {
  local status=0

  parse_args "$@"
  prepare_dirs
  check_prereqs

  if [[ -f "${INPUT_PATH}" && ${BATCH_MODE} -eq 1 ]]; then
    fail "--batch expects --input to be a directory"
  fi

  if [[ -d "${INPUT_PATH}" && ${BATCH_MODE} -eq 0 ]]; then
    fail "Input is a directory; pass --batch to process it"
  fi

  if [[ ${BATCH_MODE} -eq 1 ]]; then
    if ! process_batch; then
      status=1
    fi
  else
    require_file "${INPUT_PATH}"
    local sample_id
    if [[ -n "${SAMPLE_NAME}" ]]; then
      sample_id=${SAMPLE_NAME}
    else
      sample_id=$(basename "${INPUT_PATH}")
      sample_id=${sample_id%.raw}
      sample_id=${sample_id%.RAW}
    fi
    if ! process_sample "${INPUT_PATH}" "${sample_id}"; then
      status=1
    fi
  fi

  if [[ ${status} -eq 0 ]]; then
    log "Pipeline finished successfully"
  else
    log "Pipeline finished with failures"
    return 1
  fi
}

main "$@"