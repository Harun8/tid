#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="/Users/harun/Documents/talk"
SERVER_DIR="$ROOT_DIR/server"
LOG_DIR="$ROOT_DIR/.validation"

mkdir -p "$LOG_DIR"
cd "$SERVER_DIR"

export HOME="/Users/harun"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-3000}"
export TID_TRACE="${TID_TRACE:-1}"

printf '%s starting Tid backend host=%s port=%s\n' "$(date -Iseconds)" "$HOST" "$PORT" \
  >> "$LOG_DIR/backend-launchagent-wrapper.log"

exec /opt/homebrew/bin/node "$SERVER_DIR/dist/index.js"
