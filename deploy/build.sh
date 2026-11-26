#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-$(git rev-parse --short=12 HEAD)}"
[[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || { echo 'Invalid version'; exit 1; }
out="${2:-/tmp/chatdev-release-$version}"
mkdir -p "$out"
# Use a clean context; the root development ignore file excludes frontend.
context=$(mktemp -d)
trap 'rm -rf "$context"' EXIT
tar --exclude=.git --exclude=.venv --exclude=node_modules --exclude=dist --exclude='.env*' --exclude=.uv-cache --exclude=data --exclude=WareHouse --exclude=temp --exclude=logs --exclude=__pycache__ --exclude=.pytest_cache -cf - . | tar -C "$context" -xf -
sed '\|^/frontend$|d' .dockerignore > "$context/.dockerignore"
build_options=()
if [[ -n "${BUILD_CA_BUNDLE:-}" ]]; then
  build_options+=(--secret "id=build_ca,src=$BUILD_CA_BUNDLE")
fi
docker build "${build_options[@]}" --platform linux/amd64 -f "$context/deploy/Dockerfile" -t "chatdev:$version" "$context"
docker save "chatdev:$version" | gzip > "$out/images.tar.gz"
cp deploy/compose.yaml deploy/deploy.sh "$out/"
printf '%s\n' "$version" > "$out/VERSION"
echo "Release prepared: $out"
