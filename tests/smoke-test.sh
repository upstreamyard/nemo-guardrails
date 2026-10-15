#!/usr/bin/env bash
# Smoke test for the NeMo Guardrails image. CI runs it before publishing; run it locally too:
#   tests/smoke-test.sh nemo-guardrails:dev
#
# Everything runs on an internal Docker network without internet access, against a mock
# OpenAI-compatible LLM (tests/mock-llm.py) and an OpenTelemetry Collector.
set -euo pipefail

IMAGE=${1:?usage: $0 <image>}
TESTS=$(cd "$(dirname "$0")" && pwd)
NET=ngsmoke$$
CURL_IMAGE=curlimages/curl:8.11.1
PY_IMAGE=python:3.12-slim
OTEL_IMAGE=otel/opentelemetry-collector-contrib:0.114.0
failures=0

cleanup() {
  docker rm -f "$NET-llm" "$NET-otel" "$NET-gr" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }
check() { # name, output, expected text
  if grep -qF -- "$3" <<<"$2"; then pass "$1"; else fail "$1"; echo "       expected: $3"; echo "       got: ${2:0:500}"; fi
}
check_not() { # name, output, text that must not appear
  if grep -qF -- "$3" <<<"$2"; then fail "$1"; echo "       unexpected: $3"; else pass "$1"; fi
}

api() { docker run --rm --network "$NET" "$CURL_IMAGE" -sS --max-time 120 "$@" || true; }
# chat <message> [extra JSON fields, e.g. ,"stream":true]
chat() {
  api -H 'Content-Type: application/json' http://gr:8000/v1/chat/completions \
    -d "{\"model\":\"mock-model\",\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}]${2:-}}"
}

# start <docker run options...> -- [command...]: starts the image as "gr" and waits for its HEALTHCHECK
start() {
  local opts=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do opts+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  docker rm -f "$NET-gr" >/dev/null 2>&1 || true
  docker run -d --name "$NET-gr" --network "$NET" --network-alias gr \
    -e DO_NOT_TRACK=true -e OPENAI_API_KEY=sk-smoke -e MAIN_MODEL_BASE_URL=http://llm:8080/v1 \
    "${opts[@]}" "$IMAGE" "$@" >/dev/null
  for _ in $(seq 1 60); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$NET-gr" 2>/dev/null || echo gone)
    case $status in
      healthy) pass "container healthy (HEALTHCHECK)"; return 0 ;;
      gone) break ;;
    esac
    [ "$(docker inspect -f '{{.State.Running}}' "$NET-gr")" = "true" ] || break
    sleep 2
  done
  fail "container healthy (HEALTHCHECK)"; docker logs "$NET-gr" 2>&1 | tail -40; exit 1
}

docker network create --internal "$NET" >/dev/null
docker run -d --name "$NET-llm" --network "$NET" --network-alias llm \
  -v "$TESTS/mock-llm.py:/mock-llm.py:ro" "$PY_IMAGE" python /mock-llm.py 8080 >/dev/null
docker run -d --name "$NET-otel" --network "$NET" --network-alias otel \
  -v "$TESTS/otel/collector.yaml:/etc/otelcol-contrib/config.yaml:ro" "$OTEL_IMAGE" >/dev/null

echo "# 1. Default configuration, hardened: read-only root filesystem, no capabilities"
start --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges
check "runs as UID 10001" "$(docker exec "$NET-gr" id -u)" "10001"
check "GET /v1/health" "$(api http://gr:8000/v1/health)" '"status":"pass"'
check "GET /healthz" "$(api http://gr:8000/healthz)" '"status":"pass"'
check "Chat UI off by default" "$(api http://gr:8000/)" '{"status":"ok"}'
check "single config 'config'" "$(api http://gr:8000/v1/rails/configs)" '[{"id":"config"}]'
check "OpenAI-style request without config_id" "$(chat 'Hello there')" "Hello from the mock LLM."
check "input rail blocks" "$(chat 'BLOCK-ME please')" "I'm sorry, I can't respond to that."
check "output rail blocks" "$(chat 'please say forbidden')" "I'm sorry, I can't respond to that."
check "streaming answer" "$(chat 'Hello there' ',"stream":true')" "mock"
out=$(chat 'please say forbidden' ',"stream":true')
check "streaming: output rail blocks" "$out" '"type": "guardrails_violation"'
check_not "streaming: blocked text never sent" "$out" "FORBIDDEN-OUTPUT"
check "POST /v1/checks" "$(api -H 'Content-Type: application/json' http://gr:8000/v1/checks \
  -d '{"model":"mock-model","messages":[{"role":"user","content":"BLOCK-ME"}]}')" '"status":"blocked"'
check "GET /v1/models (from the LLM)" "$(api http://gr:8000/v1/models)" "mock-model"
check "language detection model offline (multilingual rails)" "$(docker exec "$NET-gr" python -c \
  "from fast_langdetect import detect; print(detect('Bonjour tout le monde, comment allez-vous ?', k=1))" 2>&1)" "'lang': 'fr'"
chat 'my secret is SECRET-PII-1' >/dev/null
check_not "messages not logged (NEMO_GUARDRAILS_LOG_LEVEL=WARNING)" "$(docker logs "$NET-gr" 2>&1)" "SECRET-PII-1"
start_ts=$(date +%s)
docker stop "$NET-gr" >/dev/null
check "clean shutdown on SIGTERM" "$(docker inspect -f 'exit={{.State.ExitCode}}' "$NET-gr") $(($(date +%s) - start_ts))s" "exit=143"

echo "# 2. Mounted multi-config folder, custom action, dialog rails, OpenTelemetry, verbose logs"
start -v "$TESTS/configs:/config:ro" -e OTEL_EXPORTER_OTLP_ENDPOINT=http://otel:4318 \
  -e NEMO_GUARDRAILS_LOG_LEVEL=INFO -- server --config=/config --default-config-id=self_check
out=$(api http://gr:8000/v1/rails/configs)
for id in custom_action dialog self_check tracing; do check "config '$id' listed" "$out" "\"id\":\"$id\""; done
check "--default-config-id used without config_id" "$(chat 'BLOCK-ME')" "I'm sorry, I can't respond to that."
check "custom Python action (actions.py) blocks" \
  "$(chat 'CUSTOM-BLOCK here' ',"guardrails":{"config_id":"custom_action"}')" "Blocked by a custom action."
check "custom Python action passes" \
  "$(chat 'Hello there' ',"guardrails":{"config_id":"custom_action"}')" "Hello from the mock LLM."
check "dialog rail via embeddings (FastEmbed model offline)" \
  "$(chat 'Hi' ',"guardrails":{"config_id":"dialog"}')" "Hello from a dialog rail!"
chat 'Hello there' ',"guardrails":{"config_id":"tracing"}' >/dev/null
sleep 8
check "OTLP traces exported" "$(docker logs "$NET-otel" 2>&1)" "guardrails.request"
chat 'my secret is SECRET-PII-2' >/dev/null
check "NEMO_GUARDRAILS_LOG_LEVEL=INFO logs messages" "$(docker logs "$NET-gr" 2>&1)" "SECRET-PII-2"

echo "# 3. check-config"
check "check-config passes valid configs" "$(docker run --rm --network "$NET" -v "$TESTS/configs:/config:ro" "$IMAGE" check-config 2>&1; echo "exit=$?")" "exit=0"
out=$(docker run --rm --network "$NET" -v "$TESTS/broken-config:/config:ro" "$IMAGE" check-config 2>&1; echo "exit=$?")
check "check-config fails a broken config" "$out" "exit=1"
check "check-config names the error" "$out" "self check inptu"

echo "# 4. Chat UI, read-only root filesystem"
start --read-only --tmpfs /tmp -e NEMO_GUARDRAILS_DISABLE_CHAT_UI=false
check "GET / redirects to the Chat UI" "$(api -o /dev/null -w '%{http_code} %{redirect_url}' http://gr:8000/)" "307 http://gr:8000/chat"
check "GET /chat/ serves the Chat UI" "$(api -L http://gr:8000/chat/)" "<html"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"; docker logs "$NET-gr" 2>&1 | tail -30; exit 1
fi
echo "All checks passed"
