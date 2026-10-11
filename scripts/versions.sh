#!/usr/bin/env bash
# Usage: scripts/versions.sh
# Which version of each service runs in each environment. "=" means same digest as the previous environment.
source "$(dirname "$0")/lib.sh"
require_yq
mapfile -t all_envs < <(envs)
{
  printf "SERVICE"
  for env in "${all_envs[@]}"; do printf "\t%s" "${env^^}"; done
  printf "\n"
  for svc in $(services); do
    printf "%s" "$svc"
    previous=""
    for env in "${all_envs[@]}"; do
      if [[ ! -d $ROOT/envs/$env/$svc ]]; then
        printf "\t-"
        continue
      fi
      tag=$(image_field "$svc" "$env" newTag)
      digest=$(image_field "$svc" "$env" digest)
      same=""
      if [[ -n $digest && $digest == "$previous" ]]; then same=" ="; fi
      printf "\t%s%s" "$tag" "$same"
      previous=$digest
    done
    printf "\n"
  done
} | column -t -s $'\t'
