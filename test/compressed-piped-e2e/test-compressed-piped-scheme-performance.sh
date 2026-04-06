#!/usr/bin/env bash
# RS(14, 10): k=10, m=4.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/compressed-piped-e2e.sh" 10 4 "$@"
