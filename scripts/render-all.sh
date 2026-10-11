#!/usr/bin/env bash
# Usage: scripts/render-all.sh <out-dir>
# Renders every envs/<env>/<service> into <out-dir>/<env>/<service>.yaml.
# Set ROOT to render a different checkout (pr-checks renders the base branch this way).
source "$(dirname "$0")/lib.sh"
[[ $# -eq 1 ]] || die "usage: $0 <out-dir>"
out=$1
for env in $(envs); do
  for dir in "$ROOT"/envs/"$env"/*/; do
    svc=$(basename "$dir")
    mkdir -p "$out/$env"
    kbuild "$dir" > "$out/$env/$svc.yaml"
    echo "rendered $env/$svc"
  done
done
