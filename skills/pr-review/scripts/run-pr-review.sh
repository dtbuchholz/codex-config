#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deep=0
args=()
for arg in "$@"; do
  if [[ "$arg" == "--deep" ]]; then
    deep=1
  else
    args+=("$arg")
  fi
done

if [[ "$deep" == 1 ]]; then
  exec bash "$script_dir/run-deep-review.sh" "${args[@]}"
fi
exec python3 "$script_dir/run-review.py" "${args[@]}"
