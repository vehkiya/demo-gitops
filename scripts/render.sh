#!/usr/bin/env bash
# Usage: scripts/render.sh <service> <env>
# Prints the manifests ArgoCD applies for <service> in <env>.
source "$(dirname "$0")/lib.sh"
[[ $# -eq 2 ]] || die "usage: $0 <service> <env>"
check_target "$1" "$2"
kbuild "$ROOT/envs/$2/$1"
