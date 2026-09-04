#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
editor_source="$repo_root/editor-web"
editor_resource="$repo_root/apple/ClairApp/EditorWeb"

npm --prefix "$editor_source" run build
mkdir -p "$editor_resource"
rsync -a --delete "$editor_source/dist/" "$editor_resource/"

printf 'build-editor-web: copied bundle to %s\n' "$editor_resource"
