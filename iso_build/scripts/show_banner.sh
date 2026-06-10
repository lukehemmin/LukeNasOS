#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export TERM="${TERM:-linux}"

exec /usr/bin/env python3 "$SCRIPT_DIR/console_tui.py"
