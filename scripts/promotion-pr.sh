#!/usr/bin/env bash
# Usage: scripts/promotion-pr.sh <service> <from-env> <to-env> [--requested-by <user>]
#
# Keeps exactly one promotion PR per service and target environment (branch promote/<service>-<to-env>) in sync
# with what runs in <from-env>:
#   - <from-env> has a newer image than <to-env>  → open the PR, or update it to the newest image
#   - <to-env> already runs that image            → close the PR if one is still open
# Merging the PR is the human checkpoint for <to-env>. Run from a clean checkout of main; needs git push rights and
# GH_TOKEN for the gh CLI.
source "$(dirname "$0")/lib.sh"
require_yq

requested_by=""
args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --requested-by) requested_by=$2; shift ;;
    *) args+=("$1") ;;
  esac
  shift
done
[[ ${#args[@]} -eq 3 ]] || die "usage: $0 <service> <from-env> <to-env> [--requested-by <user>]"
svc=${args[0]} from=${args[1]} to=${args[2]}
check_target "$svc" "$from"
check_target "$svc" "$to"
branch="promote/$svc-$to"

open_pr=$(gh pr list --head "$branch" --base main --state open --json url --jq '.[0].url // ""')

if [[ -z $(image_field "$svc" "$from" digest) ]]; then
  echo "$svc: nothing built for $from yet, skipping"
  exit 0
fi

git checkout -q -B "$branch" origin/main
declare -A result
while IFS='=' read -r key value; do
  result[$key]=$value
done < <(GITHUB_OUTPUT="" "$(dirname "$0")/promote.sh" "$svc" "$from" "$to")

if [[ ${result[changed]} != true ]]; then
  git checkout -q -- . && git checkout -q main
  echo "$svc: $to already runs ${result[new_tag]}"
  if [[ -n $open_pr ]]; then
    gh pr close "$open_pr" --delete-branch --comment "$to already runs \`${result[new_tag]}\`; nothing left to promote."
    echo "$svc: closed $open_pr"
  fi
  exit 0
fi

old=${result[old_tag]} new=${result[new_tag]} repo=${result[repo]}
title="promote($svc): $to → $new"
git commit -q -am "$title"
git push -q --force origin "$branch"
git checkout -q main

if [[ $old == sha-* ]]; then
  changes="[\`$old...$new\`](https://github.com/$repo/compare/${old#sha-}...${new#sha-})"
else
  changes="[commits up to \`$new\`](https://github.com/$repo/commits/${new#sha-})"
fi
body=$(cat <<EOF
Promotes **$svc** from **$from** to **$to**. **Merging this PR is the $to checkpoint.**

| | |
|---|---|
| $to runs now | \`$old\` |
| After merge | \`$new\` (the exact image running in $from) |
| Digest | \`${result[digest]}\` |
| Changes | $changes |

Only the image changes; \`envs/$to/$svc/application.yaml\` is untouched. This PR is kept up to date automatically:
when $from gets a newer build, it moves to that build. Merge when ready, or leave it open.
${requested_by:+
Requested by @$requested_by.}
EOF
)

if [[ -n $open_pr ]]; then
  gh pr edit "$open_pr" --title "$title" --body "$body" > /dev/null
  echo "$svc: updated $open_pr → $new"
else
  url=$(gh pr create --base main --head "$branch" --title "$title" --body "$body")
  echo "$svc: opened $url"
fi
