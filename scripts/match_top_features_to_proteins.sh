#!/usr/bin/env bash

set -euo pipefail

FEATURES_FILE=""
PROTEIN_MASSES_FILE=""
OUTPUT_FILE=""

TOP_FEATURES=10
TOP_PROTEINS=5
PPM_TOL=10
PTM_DELTAS="0,57.0215,42.0106,79.9663"
MIN_INTENSITY=0
SKIP_NONCANON=0

usage() {
  cat <<'EOF'
Usage:
  match_top_features_to_proteins.sh \
    --features <neutral_masses.tsv> \
    --protein-masses <protein_masses.tsv> \
    --output <protein_matches.tsv> \
    [--top-features 10] \
    [--top-proteins 5] \
    [--ppm 10] \
    [--ptm-deltas "0,57.0215,42.0106,79.9663"] \
    [--min-intensity 0] \
    [--skip-noncanon 0]

Required input columns:
  --features: sample_id, flashdeconv_feature_id, neutral_mass, intensity, retention_time_min
  --protein-masses: entry_id, description, length, mono_mass_Da, nonCanon

Output columns:
  sample_id, flashdeconv_feature_id, feature_rank, feature_neutral_mass_Da,
  feature_intensity, feature_retention_time_min, ptm_delta_Da, ptm_label,
  candidate_rank, entry_id, description, length, protein_mono_mass_Da,
  mass_error_Da, mass_error_ppm, nonCanon
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

is_number() {
  [[ "$1" =~ ^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --features)
      FEATURES_FILE=${2:-}
      shift 2
      ;;
    --protein-masses)
      PROTEIN_MASSES_FILE=${2:-}
      shift 2
      ;;
    --output)
      OUTPUT_FILE=${2:-}
      shift 2
      ;;
    --top-features)
      TOP_FEATURES=${2:-}
      shift 2
      ;;
    --top-proteins)
      TOP_PROTEINS=${2:-}
      shift 2
      ;;
    --ppm)
      PPM_TOL=${2:-}
      shift 2
      ;;
    --ptm-deltas)
      PTM_DELTAS=${2:-}
      shift 2
      ;;
    --min-intensity)
      MIN_INTENSITY=${2:-}
      shift 2
      ;;
    --skip-noncanon)
      SKIP_NONCANON=${2:-}
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
[[ -n "${PROTEIN_MASSES_FILE}" ]] || fail "--protein-masses is required"
[[ -n "${OUTPUT_FILE}" ]] || fail "--output is required"

[[ -f "${FEATURES_FILE}" ]] || fail "Features file not found: ${FEATURES_FILE}"
[[ -f "${PROTEIN_MASSES_FILE}" ]] || fail "Protein masses file not found: ${PROTEIN_MASSES_FILE}"

[[ "${TOP_FEATURES}" =~ ^[0-9]+$ ]] || fail "--top-features must be a non-negative integer"
[[ "${TOP_PROTEINS}" =~ ^[0-9]+$ ]] || fail "--top-proteins must be a non-negative integer"
[[ "${SKIP_NONCANON}" =~ ^[01]$ ]] || fail "--skip-noncanon must be 0 or 1"
is_number "${PPM_TOL}" || fail "--ppm must be numeric"
is_number "${MIN_INTENSITY}" || fail "--min-intensity must be numeric"

if (( TOP_FEATURES == 0 || TOP_PROTEINS == 0 )); then
  mkdir -p "$(dirname "${OUTPUT_FILE}")"
  printf 'sample_id\tflashdeconv_feature_id\tfeature_rank\tfeature_neutral_mass_Da\tfeature_intensity\tfeature_retention_time_min\tptm_delta_Da\tptm_label\tcandidate_rank\tentry_id\tdescription\tlength\tprotein_mono_mass_Da\tmass_error_Da\tmass_error_ppm\tnonCanon\n' > "${OUTPUT_FILE}"
  warn "top-features or top-proteins is 0; wrote header-only output"
  exit 0
fi

if [[ -z "${PTM_DELTAS// }" ]]; then
  fail "--ptm-deltas cannot be empty"
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

features_top_tmp="${tmp_dir}/features_top.tsv"
proteins_tmp="${tmp_dir}/proteins.tsv"
candidates_tmp="${tmp_dir}/candidates.tsv"
sorted_candidates_tmp="${tmp_dir}/candidates.sorted.tsv"

mkdir -p "$(dirname "${OUTPUT_FILE}")"

# Normalize and validate protein masses table.
awk -F '\t' -v OFS='\t' -v skip_noncanon="${SKIP_NONCANON}" '
NR == 1 {
  for (i = 1; i <= NF; i++) idx[$i] = i
  req[1] = "entry_id"
  req[2] = "description"
  req[3] = "length"
  req[4] = "mono_mass_Da"
  req[5] = "nonCanon"
  for (r = 1; r <= 5; r++) {
    if (!(req[r] in idx)) {
      printf("Missing required column in protein masses table: %s\\n", req[r]) > "/dev/stderr"
      exit 2
    }
  }
  next
}
NR > 1 {
  entry = $(idx["entry_id"])
  desc = $(idx["description"])
  len = $(idx["length"])
  mono = $(idx["mono_mass_Da"])
  noncanon = $(idx["nonCanon"])

  if (entry == "" || mono == "") next
  if (mono + 0 <= 0) next
  if (skip_noncanon == 1 && noncanon != "") next

  print entry, desc, len, mono + 0, noncanon
}
' "${PROTEIN_MASSES_FILE}" > "${proteins_tmp}" || fail "Failed parsing protein masses table"

[[ -s "${proteins_tmp}" ]] || fail "No protein rows available after filtering"

if [[ ${SKIP_NONCANON} -eq 0 ]]; then
  if awk -F '\t' 'NR == 1 {next} $5 != "" {found = 1; exit} END {exit(found ? 0 : 1)}' "${proteins_tmp}"; then
    warn "Protein masses include entries with non-canonical residues (nonCanon not empty)"
  fi
fi

# Select top features by intensity with deterministic tie-breaking.
awk -F '\t' -v OFS='\t' -v min_intensity="${MIN_INTENSITY}" '
NR == 1 {
  for (i = 1; i <= NF; i++) idx[$i] = i
  req[1] = "sample_id"
  req[2] = "flashdeconv_feature_id"
  req[3] = "neutral_mass"
  req[4] = "intensity"
  req[5] = "retention_time_min"
  for (r = 1; r <= 5; r++) {
    if (!(req[r] in idx)) {
      printf("Missing required column in features table: %s\\n", req[r]) > "/dev/stderr"
      exit 2
    }
  }
  next
}
NR > 1 {
  sample_id = $(idx["sample_id"])
  feature_id = $(idx["flashdeconv_feature_id"])
  neutral_mass = $(idx["neutral_mass"])
  intensity = $(idx["intensity"])
  rt = $(idx["retention_time_min"])

  if (feature_id == "" || neutral_mass == "" || intensity == "") next
  if ((neutral_mass + 0) <= 0) next
  if ((intensity + 0) < min_intensity) next

  print sample_id, feature_id, neutral_mass + 0, intensity + 0, rt + 0
}
' "${FEATURES_FILE}" \
  | sort -t $'\t' -k4,4gr -k2,2 -k3,3g \
  | head -n "${TOP_FEATURES}" \
  | awk -F '\t' -v OFS='\t' '{print NR, $1, $2, $3, $4, $5}' > "${features_top_tmp}" || fail "Failed selecting top features"

if [[ ! -s "${features_top_tmp}" ]]; then
  printf 'sample_id\tflashdeconv_feature_id\tfeature_rank\tfeature_neutral_mass_Da\tfeature_intensity\tfeature_retention_time_min\tptm_delta_Da\tptm_label\tcandidate_rank\tentry_id\tdescription\tlength\tprotein_mono_mass_Da\tmass_error_Da\tmass_error_ppm\tnonCanon\n' > "${OUTPUT_FILE}"
  warn "No qualifying features found; wrote header-only output"
  exit 0
fi

# Generate all matching candidates within tolerance for each feature/PTM hypothesis.
awk -F '\t' -v OFS='\t' -v deltas="${PTM_DELTAS}" -v ppm_tol="${PPM_TOL}" '
function abs(x) {
  return (x < 0 ? -x : x)
}

function ptm_label(delta,   key) {
  key = sprintf("%.4f", delta)
  if (key == "0.0000") return "unmodified"
  if (key == "57.0215") return "carbamidomethyl"
  if (key == "42.0106") return "acetyl"
  if (key == "79.9663") return "phospho"
  return "delta_" key
}

BEGIN {
  n_deltas = split(deltas, raw_delta, ",")
  for (d = 1; d <= n_deltas; d++) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", raw_delta[d])
    if (raw_delta[d] == "") continue
    delta_count++
    delta_arr[delta_count] = raw_delta[d] + 0
  }
  if (delta_count == 0) {
    print "No valid PTM deltas provided" > "/dev/stderr"
    exit 2
  }
}

FNR == NR {
  p_count++
  p_entry[p_count] = $1
  p_desc[p_count] = $2
  p_len[p_count] = $3 + 0
  p_mass[p_count] = $4 + 0
  p_noncanon[p_count] = $5
  next
}

{
  f_rank = $1 + 0
  sample_id = $2
  feature_id = $3
  f_mass = $4 + 0
  f_intensity = $5 + 0
  f_rt = $6 + 0
  tol_da = f_mass * ppm_tol / 1000000.0

  for (d = 1; d <= delta_count; d++) {
    delta = delta_arr[d]
    label = ptm_label(delta)
    for (i = 1; i <= p_count; i++) {
      err_da = (p_mass[i] + delta) - f_mass
      abs_err_da = abs(err_da)
      if (abs_err_da <= tol_da) {
        err_ppm = (err_da / f_mass) * 1000000.0
        abs_err_ppm = abs(err_ppm)
        print f_rank, sample_id, feature_id, f_mass, f_intensity, f_rt, delta, label, p_entry[i], p_desc[i], p_len[i], p_mass[i], err_da, abs_err_da, err_ppm, abs_err_ppm, p_noncanon[i]
      }
    }
  }
}
' "${proteins_tmp}" "${features_top_tmp}" > "${candidates_tmp}" || fail "Failed generating match candidates"

{
  printf 'sample_id\tflashdeconv_feature_id\tfeature_rank\tfeature_neutral_mass_Da\tfeature_intensity\tfeature_retention_time_min\tptm_delta_Da\tptm_label\tcandidate_rank\tentry_id\tdescription\tlength\tprotein_mono_mass_Da\tmass_error_Da\tmass_error_ppm\tnonCanon\n'

  if [[ -s "${candidates_tmp}" ]]; then
    sort -t $'\t' -k1,1n -k14,14g -k16,16g -k11,11nr -k9,9 "${candidates_tmp}" > "${sorted_candidates_tmp}"

    awk -F '\t' -v OFS='\t' -v top_k="${TOP_PROTEINS}" '
    {
      f_rank = $1 + 0
      if (seen[f_rank] >= top_k) {
        next
      }
      seen[f_rank]++
      candidate_rank = seen[f_rank]

      printf "%s\t%s\t%d\t%.6f\t%.6f\t%.6f\t%.4f\t%s\t%d\t%s\t%s\t%d\t%.6f\t%.6f\t%.3f\t%s\n",
        $2, $3, f_rank, $4, $5, $6, $7, $8, candidate_rank, $9, $10, $11, $12, $13, $15, $17
    }
    ' "${sorted_candidates_tmp}"
  fi
} > "${OUTPUT_FILE}"

selected_feature_count=$(wc -l < "${features_top_tmp}" | awk '{print $1}')
candidate_count=0
if [[ -s "${candidates_tmp}" ]]; then
  candidate_count=$(wc -l < "${candidates_tmp}" | awk '{print $1}')
fi

matched_feature_count=0
if [[ -s "${sorted_candidates_tmp}" ]]; then
  matched_feature_count=$(cut -f1 "${sorted_candidates_tmp}" | uniq | wc -l | awk '{print $1}')
fi

zero_match_count=$((selected_feature_count - matched_feature_count))
printf 'Match summary: selected_features=%d, matched_features=%d, zero_match_features=%d, total_candidates=%d\n' \
  "${selected_feature_count}" "${matched_feature_count}" "${zero_match_count}" "${candidate_count}" >&2
