#!/bin/zsh
set -euo pipefail

cd "$(dirname -- "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not installed" >&2
  exit 1
fi

# Keep the standalone CLI version aligned with the GUI source of truth.
python3 - <<'PYVERSION'
from pathlib import Path
import re
version = re.search(r'MARKETING_VERSION: "([^"]+)"', Path('project.yml').read_text()).group(1)
p = Path('ProxyPilotCLI/Sources/ProxyPilotCommand.swift')
s = p.read_text()
s = re.sub(r'version: "[^"]+"', 'version: "' + version + '"', s, count=1)
p.write_text(s)
PYVERSION

xcodegen generate

