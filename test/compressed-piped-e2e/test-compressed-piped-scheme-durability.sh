#!/usr/bin/env bash
# RS(20, 16): k=16, m=4.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/compressed-piped-e2e.sh" 16 4 "$@"
