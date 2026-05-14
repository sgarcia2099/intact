#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

cat <<EOF
Example single-file invocation:
  ${ROOT_DIR}/pipeline.sh --input /data/run01.raw --output /data/results --sample run01

Example batch invocation with filtering:
  ${ROOT_DIR}/pipeline.sh --input /data/raw --output /data/results --batch --filter

Example post-processing protein matching:
  ${ROOT_DIR}/scripts/calc_protein_mass.sh /data/proteins.fasta > /data/results/tables/protein_masses.tsv
  ${ROOT_DIR}/scripts/match_top_features_to_proteins.sh --features /data/results/tables/run01_neutral_masses.tsv --protein-masses /data/results/tables/protein_masses.tsv --output /data/results/tables/run01_protein_matches.tsv

Example one-command batch processing through matching:
  ${ROOT_DIR}/scripts/run_batch_with_mass_mapping.sh --input /data/raw --output /data/results --protein-fasta /data/proteins.fasta --filter
EOF