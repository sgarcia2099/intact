#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

cat <<EOF
Example single-file invocation:
  ${ROOT_DIR}/pipeline.sh --input /data/run01.raw --output /data/results --sample run01

Example batch invocation with filtering:
  ${ROOT_DIR}/pipeline.sh --input /data/raw --output /data/results --batch --filter
EOF