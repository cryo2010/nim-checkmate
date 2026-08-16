#!/usr/bin/env bash
# Regenerate the example run shown in the top-level README.
#
# Uses the checkmate on PATH by default; set CHECKMATE to point at a build,
# e.g. CHECKMATE=../../checkmate ./run.sh from a source checkout.
set -euo pipefail
cd "$(dirname "$0")"

checkmate="${CHECKMATE:-checkmate}"

rm -f net_counter                 # make the 8/10 flake deterministic
# --jobs:1 forces alphabetical order (config, math, net) so the header
# lines match the README; --loop:10 drives the flake detection.
"$checkmate" --color:never --loop:10 --jobs:1 || true   # exits 1 (failures)
rm -f net_counter
