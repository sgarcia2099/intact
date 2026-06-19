#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

INPUT_PATH=""
OUTPUT_DIR=""
PROTEIN_FASTA=""
RUN_FILTER=0
DRY_RUN=0
CONTINUE_ON_ERROR=${CONTINUE_ON_ERROR:-1}
FILTER_MIN_INTENSITY_OVERRIDE=""
FILTER_MIN_QSCORE_OVERRIDE=""
host_arch=$(uname -m)
default_openms_image="garciasarah2099/intact-openms-flashdeconv:openms-3.5.0"
OPENMS_IMAGE_OVERRIDE=${OPENMS_IMAGE:-"${default_openms_image}"}
OPENMS_PLATFORM_OVERRIDE=${OPENMS_DOCKER_PLATFORM:-""}

MATCH_TOP_FEATURES=${MATCH_TOP_FEATURES:-10}
MATCH_TOP_PROTEINS=${MATCH_TOP_PROTEINS:-5}
MATCH_PPM=${MATCH_PPM:-10}
MATCH_PTM_DELTAS=${MATCH_PTM_DELTAS:-"0,57.0215,42.0106,79.9663"}
MATCH_MIN_INTENSITY=${MATCH_MIN_INTENSITY:-0}
MATCH_SKIP_NONCANON=${MATCH_SKIP_NONCANON:-0}

usage() {
  cat <<'EOF'
Usage:
  run_batch_with_mass_mapping.sh \
    --input <raw-directory> \
    --output <output-directory> \
    --protein-fasta <proteins.fasta> \
    [--filter] \
    [--filter-min-intensity 0] \
    [--filter-qscore 0.5] \
    [--openms-image <docker-image>] \
    [--openms-platform <platform>] \
    [--dry-run] \
    [--continue-on-error 0|1] \
    [--top-features 10] \
    [--top-proteins 5] \
    [--ppm 10] \
    [--ptm-deltas "0,57.0215,42.0106,79.9663"] \
    [--min-intensity 0] \
    [--skip-noncanon 0]

Description:
  1) Runs batch deconvolution pipeline over all .raw files in --input.
  2) Builds one protein mass table from --protein-fasta.
  3) Runs feature-to-protein matching for each sample table.

Outputs:
  <output>/tables/protein_masses.tsv
  <output>/tables/<sample>_protein_matches.tsv

Notes:
  --openms-image sets OPENMS_IMAGE for pipeline.sh. Default:
  - garciasarah2099/intact-openms-flashdeconv:openms-3.5.0
  --openms-platform sets OPENMS_DOCKER_PLATFORM for pipeline.sh.
  For OpenMS 3.5.0 on amd64 hosts, use linux/arm64 (requires Docker emulation).
  --filter-min-intensity overrides FILTER_MIN_INTENSITY for pipeline.sh
  and is only applied when --filter is enabled.
  --filter-qscore overrides FILTER_MIN_QSCORE for pipeline.sh and is
  only applied when --filter is enabled.
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

is_number() {
  [[ "$1" =~ ^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]]
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

pull_image_or_fail() {
  local image=$1
  local platform=${2:-}

  if [[ ${DRY_RUN} -eq 1 ]]; then
    if [[ -n "${platform}" ]]; then
      printf 'DRY_RUN: %q %q %q %q\n' docker pull --platform "${platform}" "${image}"
    else
      printf 'DRY_RUN: %q %q %q\n' docker pull "${image}"
    fi
    return 0
  fi

  if [[ -n "${platform}" ]]; then
    if ! docker pull --platform "${platform}" "${image}"; then
      fail "Unable to pull Docker image ${image} for platform ${platform}. Check that the tag exists and supports the requested platform."
    fi
  else
    if ! docker pull "${image}"; then
      fail "Unable to pull Docker image ${image}. Check that the tag exists and is public (or login if private)."
    fi
  fi
}

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
    --protein-fasta)
      PROTEIN_FASTA=${2:-}
      shift 2
      ;;
    --filter)
      RUN_FILTER=1
      shift
      ;;
    --filter-min-intensity)
      FILTER_MIN_INTENSITY_OVERRIDE=${2:-}
      shift 2
      ;;
    --filter-qscore)
      FILTER_MIN_QSCORE_OVERRIDE=${2:-}
      shift 2
      ;;
    --openms-image)
      OPENMS_IMAGE_OVERRIDE=${2:-}
      shift 2
      ;;
    --openms-platform)
      OPENMS_PLATFORM_OVERRIDE=${2:-}
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --continue-on-error)
      CONTINUE_ON_ERROR=${2:-}
      shift 2
      ;;
    --top-features)
      MATCH_TOP_FEATURES=${2:-}
      shift 2
      ;;
    --top-proteins)
      MATCH_TOP_PROTEINS=${2:-}
      shift 2
      ;;
    --ppm)
      MATCH_PPM=${2:-}
      shift 2
      ;;
    --ptm-deltas)
      MATCH_PTM_DELTAS=${2:-}
      shift 2
      ;;
    --min-intensity)
      MATCH_MIN_INTENSITY=${2:-}
      shift 2
      ;;
    --skip-noncanon)
      MATCH_SKIP_NONCANON=${2:-}
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

[[ -n "${INPUT_PATH}" ]] || fail "--input is required"
[[ -n "${OUTPUT_DIR}" ]] || fail "--output is required"
[[ -n "${PROTEIN_FASTA}" ]] || fail "--protein-fasta is required"

[[ -d "${INPUT_PATH}" ]] || fail "Input directory not found: ${INPUT_PATH}"
[[ -f "${PROTEIN_FASTA}" ]] || fail "Protein FASTA not found: ${PROTEIN_FASTA}"
[[ "${CONTINUE_ON_ERROR}" =~ ^[01]$ ]] || fail "--continue-on-error must be 0 or 1"
[[ "${MATCH_SKIP_NONCANON}" =~ ^[01]$ ]] || fail "--skip-noncanon must be 0 or 1"
[[ -n "${OPENMS_IMAGE_OVERRIDE}" ]] || fail "--openms-image cannot be empty"
if [[ "${OPENMS_PLATFORM_OVERRIDE}" == "linux/amd64" || "${OPENMS_PLATFORM_OVERRIDE}" == "linux/arm64" ]]; then
  :
elif [[ -n "${OPENMS_PLATFORM_OVERRIDE}" ]]; then
  fail "--openms-platform must be linux/amd64, linux/arm64, or empty"
fi
if [[ -n "${FILTER_MIN_INTENSITY_OVERRIDE}" ]]; then
  is_number "${FILTER_MIN_INTENSITY_OVERRIDE}" || fail "--filter-min-intensity must be numeric"
fi
if [[ -n "${FILTER_MIN_QSCORE_OVERRIDE}" ]]; then
  is_number "${FILTER_MIN_QSCORE_OVERRIDE}" || fail "--filter-qscore must be numeric"
fi

mkdir -p "${OUTPUT_DIR}/tables"

if [[ -z "${OPENMS_PLATFORM_OVERRIDE}" && "${host_arch}" == "x86_64" && "${OPENMS_IMAGE_OVERRIDE}" == *":openms-3.5.0" ]]; then
  OPENMS_PLATFORM_OVERRIDE="linux/arm64"
fi

log "Using OPENMS_IMAGE=${OPENMS_IMAGE_OVERRIDE}"
if [[ -n "${OPENMS_PLATFORM_OVERRIDE}" ]]; then
  log "Using OPENMS_DOCKER_PLATFORM=${OPENMS_PLATFORM_OVERRIDE}"
fi
if [[ "${host_arch}" == "x86_64" && "${OPENMS_IMAGE_OVERRIDE}" == *":openms-3.5.0" && "${OPENMS_PLATFORM_OVERRIDE}" == "linux/arm64" ]]; then
  log "Info: running arm64 OpenMS 3.5.0 image on amd64 host via Docker emulation"
fi

log "Validating OpenMS Docker image availability"
pull_image_or_fail "${OPENMS_IMAGE_OVERRIDE}" "${OPENMS_PLATFORM_OVERRIDE}"

env_cmd=(env "OPENMS_IMAGE=${OPENMS_IMAGE_OVERRIDE}")
if [[ -n "${OPENMS_PLATFORM_OVERRIDE}" ]]; then
  env_cmd+=("OPENMS_DOCKER_PLATFORM=${OPENMS_PLATFORM_OVERRIDE}")
fi
if [[ -n "${FILTER_MIN_INTENSITY_OVERRIDE}" ]]; then
  env_cmd+=("FILTER_MIN_INTENSITY=${FILTER_MIN_INTENSITY_OVERRIDE}")
fi
if [[ -n "${FILTER_MIN_QSCORE_OVERRIDE}" ]]; then
  env_cmd+=("FILTER_MIN_QSCORE=${FILTER_MIN_QSCORE_OVERRIDE}")
fi
pipeline_cmd=("${env_cmd[@]}" "${ROOT_DIR}/pipeline.sh" --input "${INPUT_PATH}" --output "${OUTPUT_DIR}" --batch)
if [[ ${RUN_FILTER} -eq 1 ]]; then
  pipeline_cmd+=(--filter)
fi
if [[ ${DRY_RUN} -eq 1 ]]; then
  pipeline_cmd+=(--dry-run)
fi

log "Running batch deconvolution pipeline"
if ! run_or_echo "${pipeline_cmd[@]}"; then
  fail "Batch pipeline run failed"
fi

protein_mass_tsv="${OUTPUT_DIR}/tables/protein_masses.tsv"
log "Calculating protein masses from FASTA"
if [[ ${DRY_RUN} -eq 1 ]]; then
  printf 'DRY_RUN: %q %q > %q\n' "${ROOT_DIR}/scripts/calc_protein_mass.sh" "${PROTEIN_FASTA}" "${protein_mass_tsv}"
else
  "${ROOT_DIR}/scripts/calc_protein_mass.sh" "${PROTEIN_FASTA}" > "${protein_mass_tsv}"
fi

if [[ ${RUN_FILTER} -eq 1 ]]; then
  table_pattern='*_neutral_masses.filtered.tsv'
else
  table_pattern='*_neutral_masses.tsv'
fi

match_status=0
matched_count=0

while IFS= read -r table_file; do
  sample_name=$(basename "${table_file}")
  sample_name=${sample_name%_neutral_masses.filtered.tsv}
  sample_name=${sample_name%_neutral_masses.tsv}
  match_out="${OUTPUT_DIR}/tables/${sample_name}_protein_matches.tsv"

  log "Matching proteins for sample ${sample_name}"
  if ! run_or_echo "${ROOT_DIR}/scripts/match_top_features_to_proteins.sh" \
    --features "${table_file}" \
    --protein-masses "${protein_mass_tsv}" \
    --output "${match_out}" \
    --top-features "${MATCH_TOP_FEATURES}" \
    --top-proteins "${MATCH_TOP_PROTEINS}" \
    --ppm "${MATCH_PPM}" \
    --ptm-deltas "${MATCH_PTM_DELTAS}" \
    --min-intensity "${MATCH_MIN_INTENSITY}" \
    --skip-noncanon "${MATCH_SKIP_NONCANON}"; then
    match_status=1
    log "Matching failed for sample ${sample_name}"
    if [[ ${CONTINUE_ON_ERROR} -ne 1 ]]; then
      break
    fi
  else
    matched_count=$((matched_count + 1))
  fi
done < <(find "${OUTPUT_DIR}/tables" -maxdepth 1 -type f -name "${table_pattern}" | sort)

if [[ ${matched_count} -eq 0 ]]; then
  fail "No sample tables found for matching in ${OUTPUT_DIR}/tables"
fi

log "Batch mapping summary: matched_samples=${matched_count}, status=${match_status}"

if [[ ${match_status} -ne 0 ]]; then
  exit 1
fi
