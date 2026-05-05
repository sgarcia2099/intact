#!/usr/bin/env bash

set -euo pipefail

FEATURES_FILE=""
SAMPLE_ID=""
SOURCE_FILE=""
OUTPUT_FILE=""

usage() {
  cat <<'EOF'
Usage:
  normalize_flashdeconv_output.sh --features <features.tsv> --sample <sample-id> --source <source.mzML> --output <table.tsv>
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --features)
      FEATURES_FILE=${2:-}
      shift 2
      ;;
    --sample)
      SAMPLE_ID=${2:-}
      shift 2
      ;;
    --source)
      SOURCE_FILE=${2:-}
      shift 2
      ;;
    --output)
      OUTPUT_FILE=${2:-}
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

[[ -n "${FEATURES_FILE}" ]] || fail "--features is required"
[[ -n "${SAMPLE_ID}" ]] || fail "--sample is required"
[[ -n "${SOURCE_FILE}" ]] || fail "--source is required"
[[ -n "${OUTPUT_FILE}" ]] || fail "--output is required"
[[ -f "${FEATURES_FILE}" ]] || fail "FLASHDeconv feature file not found: ${FEATURES_FILE}"

mkdir -p "$(dirname "${OUTPUT_FILE}")"

# FLASHDeconv output columns can vary across versions and settings.
# This mapper normalizes several known aliases into one stable schema.
awk -F '\t' -v OFS='\t' -v sample_id="${SAMPLE_ID}" -v source_file="${SOURCE_FILE}" '
BEGIN {
  print "sample_id", "source_file", "neutral_mass", "intensity", "retention_time_min", "charge", "quality_score", "trace_start_min", "trace_end_min", "flashdeconv_feature_id"
}
NR == 1 {
  for (i = 1; i <= NF; i++) {
    key = $i
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
    idx[key] = i
  }
  next
}
NR > 1 {
  # Prefer monoisotopic mass, then fall back to average/generic mass columns.
  mass = value(idx, "MonoisotopicMass")
  if (mass == "") mass = value(idx, "AverageMass")
  if (mass == "") mass = value(idx, "Mass")

  intensity = value(idx, "SumIntensity")
  if (intensity == "") intensity = value(idx, "Intensity")
  if (intensity == "") intensity = value(idx, "Abundance")

  rt = value(idx, "StartRetentionTime")
  if (rt == "") rt = value(idx, "RetentionTime")
  if (rt == "") rt = value(idx, "RT")

  charge = value(idx, "MinCharge")
  if (charge == "") charge = value(idx, "Charge")

  score = value(idx, "Score")
  if (score == "") score = value(idx, "Quality")
  if (score == "") score = "."

  trace_start = value(idx, "StartRetentionTime")
  trace_end = value(idx, "EndRetentionTime")
  feature_id = value(idx, "FeatureIndex")
  if (feature_id == "") feature_id = value(idx, "FeatureID")
  if (feature_id == "") feature_id = NR - 1

  if (mass != "" && intensity != "") {
    print sample_id, source_file, mass, intensity, rt, charge, score, trace_start, trace_end, feature_id
  }
}

function value(map, key,   pos) {
  pos = map[key]
  if (pos == "" || pos < 1 || pos > NF) {
    return ""
  }
  return $pos
}
' "${FEATURES_FILE}" >"${OUTPUT_FILE}"

[[ -s "${OUTPUT_FILE}" ]] || fail "Normalization output is empty or missing: ${OUTPUT_FILE}"