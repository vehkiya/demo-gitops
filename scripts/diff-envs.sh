#!/usr/bin/env bash
# Usage: scripts/diff-envs.sh <service> <env-a> <env-b>
#
# "Why does <service> behave differently in <env-b>?" Compares, in order:
#   1. the image (same digest = same code)
#   2. the override files (what humans changed)
#   3. the effective Spring config (what the app actually sees)
#   4. the rendered manifests (what ArgoCD applies: replicas, resources, ...)
source "$(dirname "$0")/lib.sh"
require_yq
[[ $# -eq 3 ]] || die "usage: $0 <service> <env-a> <env-b>"
svc=$1 a=$2 b=$3
check_target "$svc" "$a"
check_target "$svc" "$b"
here=$(dirname "$0")

section() {
  printf '\n\033[1m== %s\033[0m\n' "$*"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

show_diff() { # <label-a> <label-b> <file-a> <file-b>
  # Copy first: the inputs may be process substitutions, which can only be read once
  cat "$3" > "$tmp/a"
  cat "$4" > "$tmp/b"
  if diff -q "$tmp/a" "$tmp/b" >/dev/null; then
    echo "(identical)"
  else
    diff -u --label "$1" --label "$2" "$tmp/a" "$tmp/b" || true
  fi
}

section "Image"
for env in "$a" "$b"; do
  printf '%-6s %s:%s  %s\n' "$env" "$(image_field "$svc" "$env" newName)" "$(image_field "$svc" "$env" newTag)" \
    "$(image_field "$svc" "$env" digest)"
done
digest_a=$(image_field "$svc" "$a" digest)
if [[ -n $digest_a && $digest_a == "$(image_field "$svc" "$b" digest)" ]]; then
  echo "→ same digest: identical code, any difference is configuration"
else
  echo "→ different images"
fi

section "Env-wide overrides"
show_diff "envs/$a/application.yaml" "envs/$b/application.yaml" \
  "$ROOT/envs/$a/application.yaml" "$ROOT/envs/$b/application.yaml"

section "$svc overrides"
show_diff "envs/$a/$svc/application.yaml" "envs/$b/$svc/application.yaml" \
  "$ROOT/envs/$a/$svc/application.yaml" "$ROOT/envs/$b/$svc/application.yaml"

section "Effective $svc.* config"
# Env names are replaced by <env> so a value from the same layer in both envs doesn't show up as a change
if "$here/effective-config.sh" "$svc" "$a" --app-only --plain 2>/dev/null \
  | sed "s#/$a/#/<env>/#" > "$tmp/effective-a" \
  && "$here/effective-config.sh" "$svc" "$b" --app-only --plain 2>/dev/null \
  | sed "s#/$b/#/<env>/#" > "$tmp/effective-b"; then
  show_diff "$svc @ $a" "$svc @ $b" "$tmp/effective-a" "$tmp/effective-b"
else
  echo "(skipped: jar defaults not found, see scripts/effective-config.sh)"
fi

section "Rendered manifests"
show_diff "$a/$svc (rendered)" "$b/$svc (rendered)" <(kbuild "$ROOT/envs/$a/$svc") <(kbuild "$ROOT/envs/$b/$svc")
