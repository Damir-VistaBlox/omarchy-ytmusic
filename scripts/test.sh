#!/bin/bash
# Run every test for damir.ytmusic without writing caches into the plugin dir.
set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
cd "$ROOT"
export PYTHONDONTWRITEBYTECODE=1

# Recorded fixtures come from live responses; they must never carry session
# data. (Test code uses fake cookie names on purpose, so only fixtures are
# scanned.)
echo "== secrets check (tests/fixtures)"
if grep -rIl -E '__Secure-|SAPISID|"cookie"|^cookie:' tests/fixtures/ 2>/dev/null; then
  echo "secret-looking data found in the fixtures listed above" >&2
  exit 1
fi
echo "ok"

shopt -s nullglob
js_tests=(tests/*.test.js)
if (( ${#js_tests[@]} > 0 )); then
  echo "== node --test"
  node --test "${js_tests[@]}"
fi

echo "== pytest"
uv run --quiet --no-project --with pytest --with ytmusicapi==1.12.2 \
  pytest -p no:cacheprovider -q tests/backend "$@"
