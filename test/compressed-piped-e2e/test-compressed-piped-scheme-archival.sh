#!/usr/bin/env bash
# RS(12, 8): k=8, m=4.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/compressed-piped-e2e.sh" 8 4 "$@"
