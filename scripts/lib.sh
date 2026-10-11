# shellcheck shell=bash
# Shared helpers, sourced by the other scripts.
# Requires: kustomize (or kubectl) and mikefarah yq v4 (both preinstalled on GitHub runners).
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
YQ="${YQ:-yq}"

die() {
  echo "error: $*" >&2
  exit 1
}

require_yq() {
  "$YQ" --version 2>/dev/null | grep -q mikefarah \
    || die "needs mikefarah yq v4 (https://github.com/mikefarah/yq), or set YQ=/path/to/yq"
}

# Render one envs/<env>/<svc> directory exactly like ArgoCD does (see kustomize.buildOptions in argocd-cm).
kbuild() {
  if command -v kustomize >/dev/null; then
    kustomize build --load-restrictor LoadRestrictionsNone "$1"
  else
    kubectl kustomize --load-restrictor LoadRestrictionsNone "$1"
  fi
}

# Environments in promotion order (dev, stage, prod first; anything else after).
envs() {
  local e f
  for e in dev stage prod; do
    if [[ -f $ROOT/envs/$e/env.yaml ]]; then echo "$e"; fi
  done
  for f in "$ROOT"/envs/*/env.yaml; do
    e=$(basename "$(dirname "$f")")
    if [[ ! $e =~ ^(dev|stage|prod)$ ]]; then echo "$e"; fi
  done
}

services() {
  local d
  for d in "$ROOT"/apps/*/; do
    basename "$d"
  done
}

check_target() {
  [[ -d $ROOT/envs/$2/$1 ]] || die "no such service/environment: envs/$2/$1"
}

# image_field <svc> <env> <newName|newTag|digest>
image_field() {
  "$YQ" ".images[] | select(.name == \"$1\") | .$3 // \"\"" "$ROOT/envs/$2/$1/kustomization.yaml"
}
