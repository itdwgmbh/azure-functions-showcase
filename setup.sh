#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
for tool in az func uv; do
  command -v "$tool" >/dev/null || { echo "Required command not found: $tool" >&2; exit 1; }
done
# The SQL driver loads OpenSSL from Homebrew on macOS.
if [[ "$(uname)" == Darwin ]] && command -v brew >/dev/null; then
  export DYLD_LIBRARY_PATH="$(brew --prefix openssl@3)/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi
exec uv run --no-project --python 3.12 --with-requirements requirements.txt python scripts/setup.py "$@"
