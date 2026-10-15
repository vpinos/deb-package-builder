#!/usr/bin/env bash
# Usage: scripts/finish-debs.sh <dir> <expected-version>
#
# Checks that every .deb in <dir> has exactly the version scripts/plan.sh
# predicted (so the plan and the build scripts can't silently drift apart,
# and a build can never publish a version the plan didn't approve), then
# writes the <file>.deb.sha256 sidecars deb-repo verifies on publish.
set -euo pipefail

dir="${1:?usage: finish-debs.sh <dir> <expected-version>}"
expected="${2:?usage: finish-debs.sh <dir> <expected-version>}"

shopt -s nullglob
debs=("$dir"/*.deb)
(( ${#debs[@]} )) || { echo "No .deb files in $dir." >&2; exit 1; }

for deb in "${debs[@]}"; do
  got="$(dpkg-deb -f "$deb" Version)"
  if [[ "$got" != "$expected" ]]; then
    echo "$(basename "$deb") has version $got, but the plan expected $expected." >&2
    echo "scripts/plan.sh and the build script compute versions differently: fix one to match." >&2
    exit 1
  fi
  (cd "$dir" && sha256sum "$(basename "$deb")" > "$(basename "$deb").sha256")
  echo "OK $(basename "$deb") $got"
done
