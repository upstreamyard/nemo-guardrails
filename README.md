# NeMo Guardrails Docker image (NVIDIA NeMo Guardrails 0.24)

Production-ready, multi-arch (`amd64`, `arm64`) and signed **NeMo Guardrails Docker image**: the NVIDIA NeMo Guardrails server, an **OpenAI-compatible LLM guardrails API** that checks every user message and every model answer before it passes. Point any OpenAI client at it and you get input and output rails (jailbreak and content checks), dialog rails and PII masking in front of OpenAI, NVIDIA NIM, Azure OpenAI, vLLM, Ollama or any OpenAI-compatible model server. It **works out of the box** with a default self-check configuration, runs as non-root with a read-only root filesystem, works **air-gapped** (models included), **keeps prompts out of your logs** by default, and exports **OpenTelemetry traces** with environment variables only. Use it with Docker, Docker Compose, or Kubernetes via our **[NeMo Guardrails Helm chart](https://github.com/upstreamyard/helm-charts/tree/main/charts/nemo-guardrails)**.

> Community-maintained by **upstreamyard**. This is not an official NVIDIA NeMo Guardrails image. NeMo Guardrails is licensed under Apache-2.0 (see [Licences](#licences)). NVIDIA and NeMo are trademarks of NVIDIA Corporation.

| Registry | Image |
|---|---|
| Docker Hub | `upstreamyard/nemo-guardrails` |
| GitHub Container Registry | `ghcr.io/upstreamyard/nemo-guardrails` |

| Tag | Follows |
|---|---|
| `0.24.1`, `0.24`, `latest` | NeMo Guardrails 0.24.x, the newest release |

New NeMo Guardrails releases are built within 24 hours of their GitHub release. Pin `0.24` to get patch releases automatically.

## Why this NeMo Guardrails image

NVIDIA publishes no ready-made image of the open-source NeMo Guardrails server; its docs tell you to build the repository's `Dockerfile` yourself. We compared against that build, NeMo Guardrails 0.24.1, in October 2026.

| | Built from NVIDIA's `Dockerfile` | `upstreamyard/nemo-guardrails` |
|---|---|---|
| Published image | none, build it yourself | Docker Hub and GHCR, rebuilt for every release |
| Size (uncompressed) | 2.28 GB | 1.16 GB |
| Runs as | root | non-root UID `10001` |
| Read-only root filesystem | fails at start (Chat UI writes to the working directory) | works, with a writable `/tmp` |
| Chat UI ("for internal testing only", says NVIDIA) | on, at `/` | off; `NEMO_GUARDRAILS_DISABLE_CHAT_UI=false` turns it on |
| Messages, prompts and answers in the logs | always, for every request | off; `NEMO_GUARDRAILS_LOG_LEVEL=INFO` turns them on |
| OpenAI client without a `guardrails` field | `422`: no config_id | works: default config `config` |
| Without internet | language detection model downloaded on first use | embedding and language detection models included |
| OpenTelemetry export (OTLP) | needs your own Python code | `OTEL_EXPORTER_OTLP_ENDPOINT=...` |
| Compilers and git in the image | gcc, g++, git | none |
| Signed, SBOM, provenance | no | cosign, SBOM, SLSA provenance |
| Helm chart | none | [upstreamyard/nemo-guardrails](https://github.com/upstreamyard/helm-charts/tree/main/charts/nemo-guardrails) |

## At a glance

| | |
|---|---|
| Port | `8000` (HTTP API, Chat UI when enabled) |
| API | `POST /v1/chat/completions` (OpenAI-compatible), `POST /v1/checks`, `GET /v1/rails/configs`, `GET /v1/models` |
| Probes | `GET /v1/health` or `/healthz`: liveness only. Configurations load on the first request that uses them, not at start |
| Requires | an LLM: OpenAI (`OPENAI_API_KEY`) for the default config, or any OpenAI-compatible server |
| Config | `/config`: a NeMo Guardrails configuration folder (`config.yml`, prompts, Colang files, `actions.py`). Mount your own; check it with `check-config` |
| Runs as | UID/GID `10001`. With a read-only root filesystem, `/tmp` must be writable |
| Authentication | **none**: anyone who reaches port 8000 can use your LLM. Keep it internal or put an authenticating proxy in front |
| Resources (tested) | ready in under 2 s; ~130 MB memory idle, ~260 MB with the embedding model loaded |
| Shutdown | `SIGTERM` stops the server cleanly in under a second |

**AI agents and coding assistants:** read [`AGENTS.md`](https://github.com/upstreamyard/nemo-guardrails/blob/main/AGENTS.md) for deployment rules, and [`llms.txt`](https://github.com/upstreamyard/nemo-guardrails/blob/main/llms.txt) for an index of all docs.

## Quick start: run NeMo Guardrails in Docker

```bash
docker run -d --name nemo-guardrails -p 8000:8000 \
  -e OPENAI_API_KEY=sk-... \
  upstreamyard/nemo-guardrails:0.24
```

Send a request like to OpenAI; the `model` field picks the model:

```bash
curl http://localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "gpt-4o-mini",
  "messages": [{"role": "user", "content": "What can you do?"}]
}'
```

A message that breaks the policy gets `I'm sorry, I can't respond to that.` instead of an answer. Any OpenAI SDK works with `base_url="http://localhost:8000/v1"`.

**Fully local, no API key:** [`examples/ollama/docker-compose.yml`](https://github.com/upstreamyard/nemo-guardrails/blob/main/examples/ollama/docker-compose.yml) runs NeMo Guardrails with a model in Ollama and the Chat UI at http://localhost:8000. With Docker Compose and OpenAI: [`docker-compose.yml`](https://github.com/upstreamyard/nemo-guardrails/blob/main/docker-compose.yml).

## Configuration

### The default configuration

[`/config`](https://github.com/upstreamyard/nemo-guardrails/tree/main/config) holds one configuration (id `config`) with two **self check** rails: the main model checks each user message against a policy before answering, and each answer before it is sent. Streaming works; each chunk is checked before it is sent. It's a starting point: adapt the policies in `prompts.yml` to your use case.

The main model is `gpt-4o-mini` on OpenAI. The `model` field of a request replaces the model name. For another OpenAI-compatible server, set its URL:

```bash
docker run -d -p 8000:8000 \
  -e MAIN_MODEL_BASE_URL=http://vllm:8000/v1 -e OPENAI_API_KEY=token-or-anything \
  upstreamyard/nemo-guardrails:0.24
```

`MAIN_MODEL_BASE_URL` and `MAIN_MODEL_ENGINE` only apply to requests with a `model` field. The Chat UI sends none, so it always uses the model from `config.yml`; for the Chat UI, set the model and its `base_url` in your own config, like the [Ollama example](https://github.com/upstreamyard/nemo-guardrails/blob/main/examples/ollama/config/config.yml).

### Your own configuration

Mount your configuration folder at `/config`. Two layouts work:

- **One configuration:** `config.yml` directly in the folder. Its id is `config`, the default, so requests need no `guardrails` field.
- **Several configurations:** one sub-folder each (`/config/<id>/config.yml`). Requests choose one with `"guardrails": {"config_id": "<id>"}`; set the default for requests without it in the command:

```bash
docker run -d -p 8000:8000 -e OPENAI_API_KEY=sk-... \
  -v "$PWD/configs:/config:ro" \
  upstreamyard/nemo-guardrails:0.24 server --config=/config --default-config-id=my_config
```

A configuration can contain an `actions.py` with your own Python actions, used from Colang flows; no image rebuild needed. NeMo Guardrails' docs explain [configurations](https://docs.nvidia.com/nemo/guardrails/configure-guardrails/yaml-schema), the [guardrail catalog](https://docs.nvidia.com/nemo/guardrails/configure-guardrails/guardrail-catalog) and [custom actions](https://docs.nvidia.com/nemo/guardrails/configure-guardrails/actions/creating-actions).

### Check a configuration before deploying: `check-config`

The server loads a configuration on the first request that uses it, so a broken one only shows up as a `400` on that request. `check-config`, added by this image, builds every configuration in a folder the way the server does, without calling an LLM and without an API key:

```bash
docker run --rm -v "$PWD/config:/config:ro" upstreamyard/nemo-guardrails:0.24 check-config
# ok     config
# FAILED config: InvalidRailsConfigurationError: The provided input rail flow `self check inptu` does not exist
```

It exits with `1` if any configuration fails, so it fits CI pipelines; the Helm chart runs it as an init container. Configurations that use remote embedding models (e.g. OpenAI embeddings) need network access and the key for the check.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `OPENAI_API_KEY` | – | Key for `engine: openai` models, incl. the default config |
| `NVIDIA_API_KEY` | – | Key for `engine: nim` (NVIDIA NIM, build.nvidia.com) |
| `MAIN_MODEL_ENGINE` | engine from `config.yml` | Engine for requests with a `model` field, e.g. `openai`, `nim`, `azure`, `ollama` |
| `MAIN_MODEL_BASE_URL` | – | Endpoint for requests with a `model` field, e.g. `http://vllm:8000/v1` |
| `NEMO_GUARDRAILS_DISABLE_CHAT_UI` | `true` (NVIDIA's default: `false`) | `false` serves the Chat UI at `/chat`, and `/` redirects there |
| `NEMO_GUARDRAILS_LOG_LEVEL` | `WARNING` | Level of the `nemoguardrails` loggers. `INFO` logs every message, prompt and answer. Added by this image |
| `NEMO_GUARDRAILS_SERVER_ENABLE_CORS` | `false` | `true` allows browser requests from `NEMO_GUARDRAILS_SERVER_ALLOWED_ORIGINS` |
| `NEMO_GUARDRAILS_SERVER_ALLOWED_ORIGINS` | `*` | Comma-separated origins for CORS |
| `NEMO_GUARDRAILS_NO_USAGE_STATS` | – | `true` turns off NeMo Guardrails' anonymous usage telemetry to NVIDIA (also `DO_NOT_TRACK=true`) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | – | Turns on OpenTelemetry export, see [Tracing and metrics](#opentelemetry-tracing-and-metrics) |
| `NEMOGUARDRAILS_LLM_FRAMEWORK` | `default` | `langchain` for LangChain-only providers, see [Extending](#extending-the-image) |
| `NEMO_GUARDRAILS_HEALTHCHECK_URL` | `http://127.0.0.1:8000/v1/health` | URL of the image's `HEALTHCHECK`; change it with `--port` |

Provider keys (`AZURE_OPENAI_API_KEY`, …) and the full model configuration are in NeMo Guardrails' [model configuration reference](https://docs.nvidia.com/nemo/guardrails/configure-guardrails/yaml-schema/model-configuration).

### Server options

The command is `nemoguardrails server` with these options:

| Option | Default in this image | Description |
|---|---|---|
| `--config` | `/config` | Configuration folder |
| `--default-config-id` | `config` | Configuration for requests without `config_id` |
| `--port` | `8000` | Listening port |
| `--prefix` | – | Path prefix, e.g. `/guardrails`. In 0.24.1 it only works with several configurations in sub-folders: with one configuration, every request fails with `400` (tested). |

`--auto-reload` reloads changed configurations; NVIDIA advises against it in production.

### Telemetry

NeMo Guardrails sends anonymous usage statistics to NVIDIA by default: version, platform, LLM engine names and which rail types are configured, never prompts, keys or URLs ([NVIDIA's description](https://docs.nvidia.com/nemo/guardrails/resources/telemetry)). This image keeps that default. Set `NEMO_GUARDRAILS_NO_USAGE_STATS=true` to turn it off.

## Streaming with output rails

Output rails only allow streaming (`"stream": true`) when the configuration enables it. NeMo Guardrails' default, `stream_first: true`, sends each chunk **before** checking it: in our test, the blocked text reached the client, followed by the block message. The default config here sets `stream_first: false`, so a blocked answer never reaches the client:

```yaml
rails:
  output:
    flows: [self check output]
    streaming:
      enabled: true
      stream_first: false
```

## OpenTelemetry: tracing and metrics

Set `OTEL_EXPORTER_OTLP_ENDPOINT` and the container starts the server through `opentelemetry-instrument`, which sets up the OpenTelemetry SDK from the standard `OTEL_*` variables. Defaults: protocol `http/protobuf`, service name `nemo-guardrails`, traces and metrics exported, logs not.

```bash
docker run -d -p 8000:8000 -e OPENAI_API_KEY=sk-... \
  -e OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318 \
  -v "$PWD/config:/config:ro" upstreamyard/nemo-guardrails:0.24
```

- **Traces:** enable them in the configuration. Tested: spans `guardrails.request`, `guardrails.rail`, `guardrails.action` and one per LLM call arrive at an OpenTelemetry Collector. Message content isn't captured by default.

  ```yaml
  tracing:
    enabled: true
    adapters:
      - name: OpenTelemetry
  ```

- **Metrics** need NeMo Guardrails' experimental IORails engine: `NEMO_GUARDRAILS_IORAILS_ENGINE=1` plus `metrics: {enabled: true}` in the configuration. Tested: `guardrails.requests`, `guardrails.request.duration`, `gen_ai.client.token.usage` and more. For Prometheus, scrape them from your collector.

## Kubernetes and Helm: NeMo Guardrails Helm chart

The recommended way to run NeMo Guardrails on Kubernetes is our Helm chart ([`upstreamyard/helm-charts`](https://github.com/upstreamyard/helm-charts/tree/main/charts/nemo-guardrails)). It takes your configurations from values or ConfigMaps, checks them before each rollout, takes API keys from a Secret, and adds autoscaling and a NetworkPolicy. Tested: 0 failed requests out of 1,000 across three rolling updates.

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install guardrails upstreamyard/nemo-guardrails --set llm.openaiApiKey=sk-...
```

Running the image yourself:

1. Pass API keys from a Secret.
2. Mount your configuration from a ConfigMap at `/config`. Sub-folders don't fit in one ConfigMap: use one ConfigMap per configuration, mounted at `/config/<id>`, with an empty volume at `/config` so the image's default configuration doesn't hide them. Use a new ConfigMap name for every change: Kubernetes updates mounted ConfigMaps inside running pods, and the server loads the new files unchecked (we saw HTTP 400s from old pods after ~70 s). Run `check-config` in an init container.
3. Probes: HTTP `GET /v1/health` on port 8000 for liveness and readiness.
4. The server keeps no state for plain chat completions (clients send the history), so you can run several replicas behind one Service. A `preStop` pause of a few seconds avoids "connection refused" errors during rolling updates.
5. The server has no authentication: restrict access with a NetworkPolicy, or put an authenticating gateway in front.

The container works with `runAsNonRoot: true`, `readOnlyRootFilesystem: true` (plus an `emptyDir` at `/tmp`) and all capabilities dropped.

## Extending the image

Install extra Python packages as root into `/opt/venv`, then switch back to UID `10001`. Two tested examples:

**PII detection with Presidio** (the `sdd` extra, left out here because its spaCy model adds ~1.3 GB): [`examples/pii-detection`](https://github.com/upstreamyard/nemo-guardrails/tree/main/examples/pii-detection). Tested: messages with an email address or card number are blocked, emails in answers are masked as `<EMAIL_ADDRESS>`.

```dockerfile
FROM upstreamyard/nemo-guardrails:0.24
USER root
RUN pip --python /opt/venv/bin/python install --no-cache-dir \
    "presidio-analyzer>=2.2" "presidio-anonymizer>=2.2" \
    https://github.com/explosion/spacy-models/releases/download/en_core_web_lg-3.8.0/en_core_web_lg-3.8.0-py3-none-any.whl
USER 10001:10001
```

**LangChain providers** that aren't OpenAI-compatible (Anthropic, Vertex AI, Cohere, …): [`examples/langchain`](https://github.com/upstreamyard/nemo-guardrails/tree/main/examples/langchain). `langchain-community` is required too, although NVIDIA's docs only name `langchain` and the provider package. Tested up to the provider: the request reached Anthropic's API (we had no key for a full answer).

```dockerfile
FROM upstreamyard/nemo-guardrails:0.24
USER root
RUN pip --python /opt/venv/bin/python install --no-cache-dir langchain langchain-community langchain-anthropic
USER 10001:10001
ENV NEMOGUARDRAILS_LLM_FRAMEWORK=langchain
```

## FAQ

**How do I run NeMo Guardrails in Docker?** Use the [quick start](#quick-start-run-nemo-guardrails-in-docker); an `OPENAI_API_KEY` or an OpenAI-compatible model server is all it needs.

**Is there an official NeMo Guardrails Docker image or Helm chart?** NVIDIA publishes none for the open-source server; you build its `Dockerfile` yourself. NVIDIA's NeMo Guardrails *microservice* is a separate product from NVIDIA's NGC catalog, which we haven't tested. This image and our [Helm chart](https://github.com/upstreamyard/helm-charts/tree/main/charts/nemo-guardrails) package the open-source server.

**How do I use NeMo Guardrails with Ollama, vLLM or another local model?** Set `MAIN_MODEL_BASE_URL` to its OpenAI-compatible endpoint, or see the [Ollama example](https://github.com/upstreamyard/nemo-guardrails/tree/main/examples/ollama).

**Can I use it as a drop-in OpenAI proxy?** Yes: `/v1/chat/completions` takes OpenAI requests, and the default config needs no `guardrails` field.

**Why does every request return 400 after I mounted my config?** The configuration has an error (it loads on the first request; the log says why, and [`check-config`](#check-a-configuration-before-deploying-check-config) finds it before you deploy), or its id doesn't match `--default-config-id`.

**Why don't I see prompts in the logs?** This image sets `NEMO_GUARDRAILS_LOG_LEVEL=WARNING`, because the server would otherwise log every message and answer. Set it to `INFO` to debug.

**Which LLM should do the checks?** A capable one. With `qwen2.5:1.5b`, the self check blocked a harmful request but let a prompt injection through. NVIDIA's NemoGuard models are built for these checks.

**How do I monitor NeMo Guardrails?** Export traces and metrics over OTLP, see [OpenTelemetry](#opentelemetry-tracing-and-metrics).

**How do I run NeMo Guardrails highly available on Kubernetes?** Run several replicas of the [Helm chart](https://github.com/upstreamyard/helm-charts/tree/main/charts/nemo-guardrails); chat completions are stateless.

## Verifying images

Images are signed keylessly with [cosign](https://github.com/sigstore/cosign) and include an SBOM and SLSA provenance:

```bash
cosign verify upstreamyard/nemo-guardrails:0.24 \
  --certificate-identity-regexp '^https://github.com/upstreamyard/nemo-guardrails/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

docker buildx imagetools inspect upstreamyard/nemo-guardrails:0.24 --format '{{ json .SBOM }}'
```

## How it's built

[`.github/workflows/build.yml`](https://github.com/upstreamyard/nemo-guardrails/blob/main/.github/workflows/build.yml) checks daily for a new [NeMo Guardrails release](https://github.com/NVIDIA-NeMo/Guardrails/releases), checks out its tag and builds the [`Dockerfile`](https://github.com/upstreamyard/nemo-guardrails/blob/main/Dockerfile) for amd64 and arm64.

- **Base:** `python:3.12-slim-bookworm`; NeMo Guardrails installed with `uv` from its own lockfile.
- **Extras included:** `server`, `chat-ui`, `tracing`, `jailbreak`, `multilingual`, `gcp`. Left out: `eval` and `sdd` (see [Extending](#extending-the-image)).
- **Added:** OpenTelemetry SDK, OTLP exporter and `opentelemetry-instrument`; the embedding model `all-MiniLM-L6-v2` and the fast-langdetect language model; `tini`; our [default config](https://github.com/upstreamyard/nemo-guardrails/tree/main/config); a start-up hook for `NEMO_GUARDRAILS_LOG_LEVEL`; the [`check-config`](https://github.com/upstreamyard/nemo-guardrails/blob/main/python/check-config) command.
- **Like NVIDIA's release build:** the example bots are copied into the package, because the server fails to import without them.
- **Testing:** before publishing, [`tests/smoke-test.sh`](https://github.com/upstreamyard/nemo-guardrails/blob/main/tests/smoke-test.sh) runs the image without internet access against a mock LLM and checks: health, input, output and streaming rails, `/v1/checks`, a mounted multi-config folder with a Python action, dialog rails with embeddings, OTLP traces, log levels, `check-config`, the Chat UI, read-only root filesystem and clean shutdown.

## Licences

| Component | Licence | Licence text in the image | Source code |
|---|---|---|---|
| NVIDIA NeMo Guardrails | Apache-2.0 | `/licenses/nemo-guardrails/` (incl. third-party licences) | [NVIDIA-NeMo/Guardrails](https://github.com/NVIDIA-NeMo/Guardrails) at tag `v<version>` |
| Python packages (FastAPI, Chainlit, OpenTelemetry, …) | various, mostly MIT, BSD, Apache-2.0 | in each package's `*.dist-info` under `/opt/venv` | PyPI |
| all-MiniLM-L6-v2 (ONNX by Qdrant) | Apache-2.0 | – | [Hugging Face](https://huggingface.co/Qdrant/all-MiniLM-L6-v2-onnx) |
| fastText language identification model `lid.176` | CC BY-SA 3.0 | – | [fastText](https://fasttext.cc/docs/en/language-identification.html) |
| Debian packages, Python | various, incl. GPL | `/usr/share/doc/*/copyright` | Debian and Python source archives |
| Our packaging (Dockerfile, scripts, config) | Apache-2.0 | – | this repository |

## Support

Issues with the image: [open an issue here](https://github.com/upstreamyard/nemo-guardrails/issues). Questions about NeMo Guardrails itself: [NeMo Guardrails on GitHub](https://github.com/NVIDIA-NeMo/Guardrails).
