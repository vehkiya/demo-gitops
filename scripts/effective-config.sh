#!/usr/bin/env bash
# Usage: scripts/effective-config.sh <service> <env> [--app-only] [--plain] [--jar <application.yaml>]
#
# Prints the configuration <service> ends up with in <env>: one property per line, with the layer the value comes
# from. Same precedence as Spring Boot at startup (lowest first):
#   1. jar defaults          src/main/resources/application.yaml (+ its on-cloud-platform: kubernetes document)
#   2. env-wide overrides    envs/<env>/application.yaml
#   3. service overrides     envs/<env>/<service>/application.yaml
#   4. environment variables platform settings from components/spring-boot, secrets from the ExternalSecret
#
# Jar defaults are read from, in order: --jar, the service repo on GitHub at the commit deployed in <env>
# (image tag sha-<commit>), a sibling checkout ../demo-<service>-service.
source "$(dirname "$0")/lib.sh"
require_yq

app_only=false
plain=false
jar=""
args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --app-only) app_only=true ;;
    --plain) plain=true ;; # tab-separated, no header: for diffing
    --jar) jar=$2; shift ;;
    *) args+=("$1") ;;
  esac
  shift
done
[[ ${#args[@]} -eq 2 ]] || die "usage: $0 <service> <env> [--app-only] [--plain] [--jar <application.yaml>]"
svc=${args[0]} env=${args[1]}
check_target "$svc" "$env"

image=$(image_field "$svc" "$env" newName)  # ghcr.io/<owner>/<repo>
tag=$(image_field "$svc" "$env" newTag)
repo=${image#*/}
jar_file=$(mktemp)
trap 'rm -f "$jar_file"' EXIT

if [[ -n $jar ]]; then
  cp "$jar" "$jar_file"
  jar_source=$jar
elif [[ $tag == sha-* ]] \
  && curl -fsSL "https://raw.githubusercontent.com/$repo/${tag#sha-}/src/main/resources/application.yaml" \
    -o "$jar_file" 2>/dev/null; then
  jar_source="github.com/$repo @ ${tag#sha-} (the version deployed in $env)"
elif [[ -f $ROOT/../${repo#*/}/src/main/resources/application.yaml ]]; then
  cp "$ROOT/../${repo#*/}/src/main/resources/application.yaml" "$jar_file"
  jar_source="../${repo#*/} (local checkout; may differ from the version deployed in $env)"
else
  die "cannot find jar defaults for $svc; pass --jar <path/to/application.yaml>"
fi

# props <layer> <file> [yq selector]: "layer<TAB>key<TAB>value" per property, lists as key[0]
props() {
  "$YQ" -o=props "${3:-.}" "$2" \
    | sed -E -e '/^#/d' -e '/ = /!d' -e ':a' -e 's/^([^ ]*)\.([0-9]+)(\.| = )/\1[\2]\3/' -e 'ta' \
    | awk -v layer="$1" '{ i = index($0, " = "); print layer "\t" substr($0, 1, i - 1) "\t" substr($0, i + 3) }'
}

# env_props <layer> <yq expression producing "NAME<TAB>value"> <rendered>: env vars mapped to property names
env_props() {
  "$YQ" "$2" "$3" | awk -v layer="$1" -F '\t' '
    $1 == "SPRING_CONFIG_ADDITIONAL_LOCATION" || $1 == "JAVA_TOOL_OPTIONS" { next }
    { key = tolower($1); gsub(/_/, ".", key); print layer "\t" key "\t" $2 }'
}

rendered=$(mktemp)
trap 'rm -f "$jar_file" "$rendered"' EXIT
kbuild "$ROOT/envs/$env/$svc" > "$rendered"

{
  for doc in $("$YQ" -N 'document_index' "$jar_file" | sort -u); do
    doc_props=$(props jar "$jar_file" "select(document_index == $doc)")
    if grep -q $'\tspring.config.activate.on-cloud-platform\tkubernetes$' <<< "$doc_props"; then
      # shellcheck disable=SC2001 # per-line anchor, not expressible with ${var//}
      sed 's/^jar\t/jar (kubernetes)\t/' <<< "$doc_props"
    elif ! grep -q $'\tspring.config.activate.' <<< "$doc_props"; then
      echo "$doc_props"
    fi
  done
  [[ -f $ROOT/envs/$env/application.yaml ]] && props "envs/$env/application.yaml" "$ROOT/envs/$env/application.yaml"
  props "envs/$env/$svc/application.yaml" "$ROOT/envs/$env/$svc/application.yaml"
  env_props "platform env" \
    'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.name == "app") | .env[] | .name + "\t" + .value' \
    "$rendered"
  env_props "secret" \
    'select(.kind == "ExternalSecret") | .spec.data[] | .secretKey + "\t<secret " + .remoteRef.key + "#" + .remoteRef.property + ">"' \
    "$rendered"
} | awk -F '\t' -v app_only="$app_only" -v prefix="$svc." '
    $2 ~ /^spring\.config\.activate\./ { next }
    {
      norm = tolower($2); gsub(/-/, "", norm)          # Spring relaxed binding: api-key == apikey == APIKEY
      if (!(norm in name)) name[norm] = $2
      value[norm] = $3; layer[norm] = $1               # later (higher precedence) layers win
    }
    END {
      for (n in name) {
        if (app_only == "true" && index(name[n], prefix) != 1) continue
        print name[n] "\t= " value[n] "\t# " layer[n]
      }
    }' \
  | sort \
  | if [[ $plain == true ]]; then
    cat
  else
    echo "# $svc in $env, image $tag"
    echo "# jar defaults from $jar_source"
    column -t -s $'\t'
  fi
