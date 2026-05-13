#!/bin/zsh
cd "$(dirname "$0")/.." || exit 1
./scripts/build_and_install.sh
status=$?
echo
echo "Press any key to close..."
read -k1 -s
exit $status
