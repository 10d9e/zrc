#!/usr/bin/env bash
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/compressed-piped-e2e.sh" 1 16 "$@"
