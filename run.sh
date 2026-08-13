#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -d .venv ]]; then
  echo "[run] creating .venv (one-time setup)..."
  python3 -m venv .venv
  ./.venv/bin/pip install --upgrade pip wheel
  ./.venv/bin/pip install -r requirements.txt
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" || -z "${ELEVENLABS_API_KEY:-}" ]]; then
  echo "[run] ERROR: ANTHROPIC_API_KEY or ELEVENLABS_API_KEY missing." >&2
  echo "[run] copy .env.example to .env and paste your keys." >&2
  exit 1
fi

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 127.0.0.1)"
PORT="${PORT:-8082}"

echo "[run] starting on http://${LAN_IP}:${PORT}  (loading Whisper takes ~10-30s the first time)"
echo "[run] iOS BACKEND_URL = http://${LAN_IP}:${PORT}"

exec ./.venv/bin/uvicorn backend.main:app \
  --host "${HOST:-0.0.0.0}" \
  --port "${PORT}" \
  --log-level info
