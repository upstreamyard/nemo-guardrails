# Container image for NVIDIA NeMo Guardrails (https://github.com/NVIDIA-NeMo/Guardrails)
# Maintained by upstreamyard. Builds the NeMo Guardrails source code, checked out into
# ./upstream at the release tag selected by CI.

ARG PY_VERSION=3.12
FROM python:${PY_VERSION}-slim-bookworm AS base

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=on

RUN addgroup --system --gid 10001 app && adduser --system --uid 10001 --ingroup app --home /home/app app

# -----------------------------
# Builder
# -----------------------------
FROM base AS builder

COPY --from=ghcr.io/astral-sh/uv:0.11.26 /uv /bin/uv

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/opt/venv

WORKDIR /build
COPY upstream/ ./

# NeMo Guardrails from its lockfile, with the extras a server needs. Left out: `eval`
# (Streamlit/pandas evaluation tooling) and `sdd` (Presidio and its spaCy model add
# ~1.3 GB; see examples/pii-detection).
# Like NVIDIA's release build (.github/scripts/build.sh), the example bots go into the
# package first: the server imports them as its fallback config and fails without them.
RUN mkdir -p nemoguardrails/examples && cp -r examples/bots nemoguardrails/examples/bots && \
    uv sync --locked --no-dev --no-editable \
    --extra server --extra chat-ui --extra tracing --extra jailbreak --extra multilingual --extra gcp

# OpenTelemetry SDK and OTLP exporter, so traces and metrics can be exported with
# OTEL_* environment variables only (see docker-entrypoint.sh).
ARG OTEL_SDK_VERSION=1.43.0
ARG OTEL_DISTRO_VERSION=0.64b0
RUN uv pip install --python /opt/venv/bin/python \
    "opentelemetry-sdk==${OTEL_SDK_VERSION}" \
    "opentelemetry-exporter-otlp-proto-http==${OTEL_SDK_VERSION}" \
    "opentelemetry-distro==${OTEL_DISTRO_VERSION}"

# Models NeMo Guardrails would otherwise download on first use, so air-gapped clusters
# work: the default embedding model (all-MiniLM-L6-v2: dialog rails, knowledge bases) and
# the language detection model (multilingual content safety).
ENV FASTEMBED_CACHE_PATH=/opt/fastembed \
    FTLANG_CACHE=/opt/fasttext-langdetect
RUN /opt/venv/bin/python -c "from fastembed import TextEmbedding; TextEmbedding('sentence-transformers/all-MiniLM-L6-v2')" && \
    /opt/venv/bin/python -c "from fast_langdetect import detect; print(detect('Bonjour tout le monde', k=1))"

# -----------------------------
# Runtime
# -----------------------------
FROM base AS final

ARG PY_VERSION
ARG NEMO_GUARDRAILS_VERSION=unknown

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /opt/fastembed /opt/fastembed
COPY --from=builder /opt/fasttext-langdetect /opt/fasttext-langdetect
COPY python/upstreamyard_logging.py python/upstreamyard-logging.pth /opt/venv/lib/python${PY_VERSION}/site-packages/
COPY upstream/LICENSE.md upstream/LICENSE-Apache-2.0.txt /licenses/nemo-guardrails/
COPY upstream/LICENCES-3rd-party /licenses/nemo-guardrails/LICENCES-3rd-party
COPY config/ /config/
COPY --chmod=755 docker-entrypoint.sh python/check-config /usr/local/bin/

WORKDIR /app

ENV PATH=/opt/venv/bin:$PATH \
    HOME=/home/app \
    FASTEMBED_CACHE_PATH=/opt/fastembed \
    FTLANG_CACHE=/opt/fasttext-langdetect \
    NEMO_GUARDRAILS_DISABLE_CHAT_UI=true \
    CHAINLIT_APP_ROOT=/tmp \
    NEMO_GUARDRAILS_LOG_LEVEL=WARNING

LABEL org.opencontainers.image.title="nemo-guardrails" \
      org.opencontainers.image.description="NeMo Guardrails Docker image: NVIDIA NeMo Guardrails server, OpenAI-compatible LLM guardrails API. Non-root, multi-arch, signed." \
      org.opencontainers.image.version="${NEMO_GUARDRAILS_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="upstreamyard" \
      org.opencontainers.image.url="https://github.com/upstreamyard/nemo-guardrails" \
      org.opencontainers.image.documentation="https://github.com/upstreamyard/nemo-guardrails#readme"

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["python", "-c", "import os, sys, urllib.request; sys.exit(0 if urllib.request.build_opener(urllib.request.ProxyHandler({})).open(os.environ.get('NEMO_GUARDRAILS_HEALTHCHECK_URL', 'http://127.0.0.1:8000/v1/health'), timeout=4).status == 200 else 1)"]

USER 10001:10001

ENTRYPOINT ["/usr/bin/tini", "--", "docker-entrypoint.sh"]
CMD ["server", "--config=/config", "--default-config-id=config"]
