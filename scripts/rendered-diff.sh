#!/usr/bin/env bash
# Usage: scripts/rendered-diff.sh <base-rendered-dir> <head-rendered-dir>
# Prints a markdown PR comment with the rendered-manifest diff per app (both dirs come from render-all.sh).
# Reviewers see exactly what ArgoCD will change, including the ConfigMap content and the image.
source "$(dirname "$0")/lib.sh"
[[ $# -eq 2 ]] || die "usage: $0 <base-rendered-dir> <head-rendered-dir>"
base=$1 head=$2
max_chars=60000 # GitHub comments are limited to 65536 characters

body=""
changed=0
while read -r app; do
  # -N: an app that exists on one side only (added or removed) diffs against an empty file
  diff=$(diff -uN --label "base/$app" --label "pr/$app" "$base/$app" "$head/$app" || true)
  [[ -n $diff ]] || continue
  changed=$((changed + 1))
  note=""
  if [[ ! -f $base/$app ]]; then note=" · new app"; fi
  if [[ ! -f $head/$app ]]; then note=" · removed app"; fi
  added=$(grep -c '^+[^+]' <<< "$diff" || true)
  removed=$(grep -c '^-[^-]' <<< "$diff" || true)
  body+=$'\n'"<details open><summary><b>${app%.yaml}</b> (+$added −$removed$note)</summary>"$'\n\n```diff\n'"$diff"$'\n```\n</details>\n'
done < <({
  (cd "$base" && find . -name '*.yaml')
  (cd "$head" && find . -name '*.yaml')
} | sed 's#^\./##' | sort -u)

echo "<!-- rendered-diff -->"
echo "### Rendered manifest changes"
if ((changed == 0)); then
  echo "No changes to what ArgoCD applies."
  exit 0
fi
echo "$changed app(s) change. This is exactly what ArgoCD will apply after merge."
if ((${#body} > max_chars)); then
  echo "${body:0:max_chars}"
  echo
  echo "_Diff truncated. Run \`scripts/render-all.sh\` locally for the full output._"
else
  echo "$body"
fi
