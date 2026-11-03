#!/usr/bin/env bash
# Wspólne wejście do modelu AI dla workflowów n8n: prompt ze stdin, odpowiedź na stdout.
# Prompt przychodzi przez stdin (n8n koduje go w base64), więc treść od klienta nigdy
# nie trafia do linii poleceń powłoki.
#
# Tryb testowy: LLM_MOCK=<nazwa> zwraca n8n/fixtures/llm-<nazwa>.json zamiast pytać model.
# Działa tylko przy ALLOW_LLM_MOCK=1 i nazwie pasującej do ^[a-z0-9-]+$.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

if [ -n "${LLM_MOCK:-}" ]; then
  if [ "${ALLOW_LLM_MOCK:-}" != "1" ]; then
    echo "MOCK_NOT_ALLOWED" >&2
    exit 2
  fi
  if ! [[ "$LLM_MOCK" =~ ^[a-z0-9-]+$ ]]; then
    echo "INVALID_MOCK_NAME" >&2
    exit 2
  fi
  cat "$root/n8n/fixtures/llm-$LLM_MOCK.json"
  exit 0
fi

prompt="$(cat)"
# Model dostaje minimalne środowisko: n8n ma w swoim kluczu service_role, którego model nie może zobaczyć.
exec env -i HOME="$HOME" PATH="$PATH" USER="${USER:-}" LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \
  agy --model "${LLM_MODEL:-gemini-3.8-flash-medium}" --print-timeout "${LLM_TIMEOUT:-90s}" --print "$prompt"
