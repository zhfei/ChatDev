#!/usr/bin/env bash
# The local .env is trusted, Bash-compatible configuration; never enable xtrace.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo 'Copy .env.example to .env and fill in deployment settings.' >&2; exit 1; }
set -a
source .env
set +a
: "${DEPLOY_HOST:?Set DEPLOY_HOST in .env}"
: "${DEPLOY_USER:?Set DEPLOY_USER in .env}"
: "${API_KEY:?Set API_KEY in .env}"
DEPLOY_PORT=${DEPLOY_PORT:-22}
DEPLOY_PATH=${DEPLOY_PATH:-/opt/chatdev}
[[ "$DEPLOY_HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ && "$DEPLOY_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || { echo 'Invalid SSH host/user'; exit 1; }
[[ "$DEPLOY_PORT" =~ ^[0-9]+$ ]] && (( DEPLOY_PORT > 0 && DEPLOY_PORT < 65536 )) || { echo 'Invalid SSH port'; exit 1; }
[[ "$DEPLOY_PATH" =~ ^/[a-zA-Z0-9_./-]+$ && "$DEPLOY_PATH" != / && "$DEPLOY_PATH" != *..* ]] || { echo 'DEPLOY_PATH must be an absolute path without spaces or ..'; exit 1; }
[[ "$API_KEY" != sk-your-openai-api-key-here ]] || { echo 'Replace the example API_KEY'; exit 1; }
for tool in docker ssh tar gzip git; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool"; exit 1; }; done
docker info >/dev/null
ssh_options=(-p "$DEPLOY_PORT" -o ConnectTimeout=15)
if [[ -n "${DEPLOY_SSH_KEY:-}" ]]; then
  identity=${DEPLOY_SSH_KEY/#\~/$HOME}
  [[ -f "$identity" ]] || { echo 'DEPLOY_SSH_KEY does not exist'; exit 1; }
  ssh_options+=(-i "$identity" -o IdentitiesOnly=yes)
fi
target="$DEPLOY_USER@$DEPLOY_HOST"
echo '1/3 Checking VPS access and Docker...'
ssh "${ssh_options[@]}" "$target" "set -eu; test \"\$(uname -m)\" = x86_64; docker info >/dev/null; docker compose version; mkdir -p '$DEPLOY_PATH'; test -w '$DEPLOY_PATH'"
version=${DEPLOY_VERSION:-$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short=8 HEAD)}
release=$(mktemp -d)
trap 'rm -rf "$release"' EXIT
umask 077
# Forward only application settings. SSH configuration stays on the local machine.
: > "$release/.env"
BASE_URL=${BASE_URL:-https://dashscope.aliyuncs.com/compatible-mode/v1}
MAC_ALLOW_UNSAFE_CODE_EXECUTION=${MAC_ALLOW_UNSAFE_CODE_EXECUTION:-0}
for name in BASE_URL API_KEY MAC_ALLOW_UNSAFE_CODE_EXECUTION SERPER_DEV_API_KEY JINA_API_KEY GEMINI_API_KEY MEM0_API_KEY; do
  value=${!name:-}
  [[ -n "$value" ]] || continue
  [[ "$value" != *"'"* && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || { echo "Unsupported quote/newline in $name"; exit 1; }
  printf "%s='%s'\n" "$name" "$value" >> "$release/.env"
done
echo '2/3 Building and packaging image locally...'
if bash deploy/build.sh "$version" "$release"; then
  :
else
  status=$?
  echo 'Build failed; upload and deployment cancelled.' >&2
  exit "$status"
fi
# Check artifacts as well as exit status: an incomplete package must never
# open another SSH connection or overwrite the deployed files.
for artifact in images.tar.gz VERSION compose.yaml deploy.sh; do
  [[ -s "$release/$artifact" ]] || { echo "Build output missing: $artifact; deployment cancelled." >&2; exit 1; }
done
[[ "$(cat "$release/VERSION")" == "$version" ]] || { echo 'Build version mismatch; deployment cancelled.' >&2; exit 1; }
gzip -t "$release/images.tar.gz" || { echo 'Invalid image archive; deployment cancelled.' >&2; exit 1; }
echo '3/3 Uploading over SSH and deploying...'
# Extract in a private staging directory; incomplete transfers do not overwrite config.
tar -C "$release" -cf - images.tar.gz VERSION compose.yaml deploy.sh .env |
  ssh "${ssh_options[@]}" "$target" "set -eu; umask 077; cd '$DEPLOY_PATH'; stage=\$(mktemp -d .upload.XXXXXX); trap 'rm -rf \"\$stage\"' EXIT; tar -xf - -C \"\$stage\"; for f in images.tar.gz VERSION compose.yaml deploy.sh .env; do test -f \"\$stage/\$f\"; done; cp \"\$stage/.env\" .env.next; chmod 600 .env.next; mv .env.next .env; mv \"\$stage/images.tar.gz\" \"\$stage/VERSION\" \"\$stage/compose.yaml\" \"\$stage/deploy.sh\" .; bash deploy.sh"
printf '\nDeployment complete. Access from your computer:\nssh -N -p %q ' "$DEPLOY_PORT"
if [[ -n "${identity:-}" ]]; then printf -- '-i %q ' "$identity"; fi
printf -- '-L 8080:127.0.0.1:8080 %q\n' "$target"
echo 'Then open http://localhost:8080'
