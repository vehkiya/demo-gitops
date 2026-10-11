#!/usr/bin/env bash
# Usage:
#   scripts/promote.sh <service> <from-env> <to-env>               copy the image (tag + digest) between envs
#   scripts/promote.sh --set <service> <env> <image:tag@digest>    set the image (used by service CI for dev)
#
# Only touches the images: entry of envs/<env>/<service>/kustomization.yaml. Config is never promoted.
# On GitHub Actions it also writes service/from/to/old_tag/new_tag/digest/repo/changed to $GITHUB_OUTPUT.
source "$(dirname "$0")/lib.sh"
require_yq

set_image() { # <svc> <env> <name> <tag> <digest>
  "$YQ" -i "(.images[] | select(.name == \"$1\")) |= (.newName = \"$3\" | .newTag = \"$4\" | .digest = \"$5\")" \
    "$ROOT/envs/$2/$1/kustomization.yaml"
}

output() {
  echo "$1=$2"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi
}

if [[ ${1:-} == --set ]]; then
  [[ $# -eq 4 ]] || die "usage: $0 --set <service> <env> <image:tag@digest>"
  svc=$2 to=$3 ref=$4 from=""
  [[ $ref == *@sha256:* ]] || die "image reference must include a digest: $ref"
  digest=${ref##*@}
  name_tag=${ref%@*}
  tag=${name_tag##*:}
  name=${name_tag%:*}
else
  [[ $# -eq 3 ]] || die "usage: $0 <service> <from-env> <to-env>"
  svc=$1 from=$2 to=$3
  check_target "$svc" "$from"
  name=$(image_field "$svc" "$from" newName)
  tag=$(image_field "$svc" "$from" newTag)
  digest=$(image_field "$svc" "$from" digest)
  [[ -n $digest ]] || die "envs/$from/$svc has no digest yet; only CI-built images can be promoted"
fi
check_target "$svc" "$to"

old_tag=$(image_field "$svc" "$to" newTag)
old_digest=$(image_field "$svc" "$to" digest)
changed=true
if [[ $old_digest == "$digest" ]]; then changed=false; fi
set_image "$svc" "$to" "$name" "$tag" "$digest"

output service "$svc"
output from "$from"
output to "$to"
output old_tag "$old_tag"
output new_tag "$tag"
output digest "$digest"
output repo "${name#*/}" # ghcr.io/vehkiya/demo-orders-service -> vehkiya/demo-orders-service
output changed "$changed"
