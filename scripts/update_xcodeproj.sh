#!/bin/zsh
set -euo pipefail

cd "$(dirname -- "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not installed" >&2
  exit 1
fi

xcodegen generate

