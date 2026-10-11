#!/usr/bin/env bash
# Usage: scripts/policy.sh <rendered-dir>     (the output of render-all.sh)
# Simple guardrails checked on every PR. Exits non-zero if any rule fails.
source "$(dirname "$0")/lib.sh"
require_yq
[[ $# -eq 1 ]] || die "usage: $0 <rendered-dir>"
rendered=$1
failures=0

fail() {
  echo "FAIL  $*"
  failures=$((failures + 1))
}

pass() {
  echo "ok    $*"
}

for file in "$rendered"/*/*.yaml; do
  env=$(basename "$(dirname "$file")")
  svc=$(basename "$file" .yaml)
  where="$env/$svc"

  # Secrets come from the secret store through an ExternalSecret, never from Git
  if [[ -n $("$YQ" 'select(.kind == "Secret") | .metadata.name' "$file") ]]; then
    fail "$where: contains a Secret; use an ExternalSecret instead"
  else
    pass "$where: no Secrets in Git"
  fi

  # Only service apps have a Deployment; namespace-level apps (envs/<env>/baseline) stop here
  [[ -n $("$YQ" 'select(.kind == "Deployment") | .metadata.name' "$file") ]] || continue

  # If the images: entry name doesn't match the container, the placeholder image would be deployed
  image=$("$YQ" 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "app") | .image' "$file")
  if [[ $image == */* ]]; then
    pass "$where: image $image"
  else
    fail "$where: image '$image' was not replaced; check the images: entry name"
  fi

  if [[ $env == prod ]]; then
    tag=$(image_field "$svc" "$env" newTag)
    if [[ $tag == bootstrap || -n $(image_field "$svc" "$env" digest) ]]; then
      pass "$where: image pinned by digest"
    else
      fail "$where: prod images must be pinned by digest (promote instead of editing by hand)"
    fi
    replicas=$("$YQ" 'select(.kind == "Deployment") | .spec.replicas' "$file")
    if ((replicas >= 2)); then
      pass "$where: $replicas replicas"
    else
      fail "$where: prod needs at least 2 replicas, has $replicas"
    fi
  fi
done

echo
((failures == 0)) || die "$failures policy check(s) failed"
echo "All policy checks passed."
