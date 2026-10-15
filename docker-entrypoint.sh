#!/bin/sh
# Runs the NeMo Guardrails CLI (`nemoguardrails <command>`), or our `check-config` command.
# With OTEL_EXPORTER_OTLP_ENDPOINT set, it starts the CLI through `opentelemetry-instrument`,
# which sets up the OpenTelemetry SDK from the OTEL_* variables. NeMo Guardrails then
# exports its traces and metrics over OTLP without any Python code in the config.
set -e

if [ "${1:-}" = "check-config" ]; then
  shift
  exec check-config "$@"
fi

if [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ] && [ "${OTEL_SDK_DISABLED:-false}" != "true" ]; then
  export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/protobuf}"
  export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-nemo-guardrails}"
  export OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"
  export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-otlp}"
  export OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-none}"
  exec opentelemetry-instrument nemoguardrails "$@"
fi

exec nemoguardrails "$@"
