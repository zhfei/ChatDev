#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
docker info >/dev/null
docker compose version >/dev/null
[[ "$(uname -m)" == x86_64 ]] || { echo 'This bundle requires an x86_64 VPS'; exit 1; }
if [[ ! -f .env ]]; then
  umask 077
  read -r -p 'Model API base URL [https://dashscope.aliyuncs.com/compatible-mode/v1]: ' base
  read -r -s -p 'Model API key: ' key; echo
  [[ -n "$key" ]] || { echo 'API key required'; exit 1; }
  # Single-quoted dotenv values are literal; reject quote/newline input.
  [[ "$key$base" != *"'"* && "$key$base" != *$'\n'* && "$key$base" != *$'\r'* ]] || exit 1
  printf "BASE_URL='%s'\nAPI_KEY='%s'\nMAC_ALLOW_UNSAFE_CODE_EXECUTION=0\n" "${base:-https://dashscope.aliyuncs.com/compatible-mode/v1}" "$key" > .env
  unset key
fi
version=$(cat VERSION)
[[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || exit 1
echo 'Loading image into Docker (this may take several minutes)...'
docker load -i images.tar.gz
# Keep previous version metadata for a manual rollback. Never delete volumes.
if [[ -f version.env ]] && ! grep -qxF "CHATDEV_VERSION=$version" version.env; then
  cp version.env previous-version.env
fi
printf 'CHATDEV_VERSION=%s\n' "$version" > version.env
docker compose --env-file version.env config --quiet
echo 'Starting container and waiting for health checks...'
docker compose --env-file version.env up -d --remove-orphans --wait --wait-timeout 180
docker compose --env-file version.env exec -T app python -c "import urllib.request,json; r=json.load(urllib.request.urlopen('http://127.0.0.1:8080/api/workflows')); assert isinstance(r['workflows'],list); print('Workflow API proxy OK')"
echo 'Deployment health checks passed.'
