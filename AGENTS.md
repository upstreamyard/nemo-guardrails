# AGENTS.md

Instructions for AI agents and coding assistants working with this repository or deploying the image it publishes: a Docker image of the NVIDIA NeMo Guardrails server (the open-source `nemoguardrails server`, not NVIDIA's NeMo Guardrails microservice from NGC).

## Image facts

| Key | Value |
|---|---|
| Image | `upstreamyard/nemo-guardrails` (Docker Hub), `ghcr.io/upstreamyard/nemo-guardrails` |
| Tags | `<version>` (e.g. `0.24.1`), `<major>.<minor>` (`0.24`), `latest` |
| Platforms | `linux/amd64`, `linux/arm64` |
| Port | `8000` |
| API | `POST /v1/chat/completions` (OpenAI-compatible; guardrails options under `"guardrails": {...}`), `POST /v1/checks`, `GET /v1/rails/configs`, `GET /v1/models` |
| Probes | `GET /v1/health` (also `/healthz`): liveness only; configurations load lazily on first use |
| Command | entrypoint runs `nemoguardrails <args>`; default args `server --config=/config --default-config-id=config`. `check-config [folder]` validates configurations instead |
| Config | `/config`. Default: one configuration (id `config`), self check input and output rails, `gpt-4o-mini` on OpenAI, output streaming with `stream_first: false` |
| User | non-root, UID/GID `10001`; read-only root filesystem works with a writable `/tmp` |
| Authentication | none in the server |
| Models in the image | FastEmbed `all-MiniLM-L6-v2` (`/opt/fastembed`), fast-langdetect `lid.176` (`/opt/fasttext-langdetect`); no runtime downloads needed |
| Python | venv at `/opt/venv` (no pip inside; use `pip --python /opt/venv/bin/python`) |
| NeMo Guardrails project | https://github.com/NVIDIA-NeMo/Guardrails (Apache-2.0) |

## Deploying the image

Rules that avoid the common failures:

- **LLM:** the default config needs `OPENAI_API_KEY`. For another OpenAI-compatible server (vLLM, Ollama, NIM, LiteLLM), set `MAIN_MODEL_BASE_URL` (and `MAIN_MODEL_ENGINE` if not `openai`). These two variables only apply to requests with a `model` field; the Chat UI sends none, so for the Chat UI put the model and `parameters.base_url` into `config.yml`.
- **Requests:** `model` is required. Without `guardrails.config_id`, the server uses `--default-config-id` (`config` in this image). With several configurations in sub-folders, set `--default-config-id=<folder name>`, or every request must name one.
- **Own configuration:** mount it at `/config`, read-only is fine. One configuration = `config.yml` at the top (id `config`); several = one sub-folder each. `actions.py` in a configuration runs as Python inside the server. Run `check-config` on every change: a broken configuration otherwise only fails (HTTP 400) on the first request that uses it.
- **`--prefix`:** in 0.24.1 it only works with sub-folder configurations; with a single top-level `config.yml` every request returns 400. Prefer path rewriting in the ingress.
- **Streaming:** `"stream": true` needs `rails.output.streaming.enabled: true` when output rails exist. Keep `stream_first: false`, otherwise blocked text is sent before the block message.
- **Security:** the server has no authentication and spends your LLM budget for anyone who can reach it. Keep it cluster-internal (NetworkPolicy) or behind an authenticating gateway. Keep the Chat UI off in production (`NEMO_GUARDRAILS_DISABLE_CHAT_UI=true`, the default here).
- **Logs:** `NEMO_GUARDRAILS_LOG_LEVEL=WARNING` (default here) keeps messages, prompts and answers out of the logs; `INFO` logs all of them.
- **Telemetry:** NeMo Guardrails sends anonymous usage statistics to NVIDIA unless `NEMO_GUARDRAILS_NO_USAGE_STATS=true` (or `DO_NOT_TRACK=true`).
- **Observability:** `OTEL_EXPORTER_OTLP_ENDPOINT` makes the entrypoint wrap the server in `opentelemetry-instrument` (protocol defaults to `http/protobuf`, port 4318). Traces also need `tracing: {enabled: true, adapters: [{name: OpenTelemetry}]}` in the config; metrics need `NEMO_GUARDRAILS_IORAILS_ENGINE=1` and `metrics: {enabled: true}` (experimental).
- **Scaling:** chat completions are stateless (clients send the history); run several replicas. `thread_id` conversations need a datastore and are not covered by this image's docs.
- **Extra Python packages** (Presidio for PII detection, LangChain providers): build `FROM upstreamyard/nemo-guardrails`, switch to `USER root`, `pip --python /opt/venv/bin/python install ...`, back to `USER 10001:10001`. LangChain providers also need `langchain-community` and `NEMOGUARDRAILS_LLM_FRAMEWORK=langchain`.

Ready-to-use manifests:

- Docker Compose with OpenAI: [`docker-compose.yml`](docker-compose.yml)
- Docker Compose with a local Ollama model and the Chat UI: [`examples/ollama/docker-compose.yml`](examples/ollama/docker-compose.yml)
- PII detection image and config: [`examples/pii-detection/`](examples/pii-detection/)
- LangChain (Anthropic) image and config: [`examples/langchain/`](examples/langchain/)
- Kubernetes: Helm chart `upstreamyard/nemo-guardrails` from `https://upstreamyard.github.io/helm-charts` (also `oci://ghcr.io/upstreamyard/charts/nemo-guardrails`), documented in https://github.com/upstreamyard/helm-charts/tree/main/charts/nemo-guardrails

Verify a deployment:

```bash
curl -s http://<host>:8000/v1/health
curl -s http://<host>:8000/v1/rails/configs
curl -s http://<host>:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<model>","messages":[{"role":"user","content":"Hello"}]}'
```

## Working on this repository

Layout:

- `Dockerfile`: builds NeMo Guardrails from its source at the release tag, which CI checks out into `./upstream/` (git-ignored), with `uv sync --locked`; adds the OpenTelemetry SDK, the two models, our config, `check-config` and the log-level hook
- `config/`: the default configuration (self check rails); `prompts.yml` comes from NeMo Guardrails' examples
- `docker-entrypoint.sh`: `check-config`, or `nemoguardrails <args>` (through `opentelemetry-instrument` when an OTLP endpoint is set)
- `python/check-config`: builds every configuration without calling an LLM
- `python/upstreamyard_logging.py` + `.pth`: applies `NEMO_GUARDRAILS_LOG_LEVEL` at Python start-up (a `.pth` file, because `opentelemetry-instrument` replaces `sitecustomize`)
- `tests/smoke-test.sh`: the test CI runs before publishing, on an internal Docker network against `tests/mock-llm.py` and an OpenTelemetry Collector; `tests/configs/` and `tests/broken-config/` are its fixtures
- `examples/`: Ollama compose, PII detection and LangChain derived images
- `.github/workflows/build.yml`: resolves the latest NeMo Guardrails release, smoke-tests, pushes multi-arch, signs and syncs the Docker Hub README

Build and test locally:

```bash
git clone --depth 1 --branch v0.24.1 https://github.com/NVIDIA-NeMo/Guardrails.git upstream
docker build -t nemo-guardrails:dev --build-arg NEMO_GUARDRAILS_VERSION=0.24.1 .
tests/smoke-test.sh nemo-guardrails:dev
```

Rules:

- Never push to `main`. Create a branch and open a pull request into `main`.
- Do not modify NeMo Guardrails' source; fix packaging in the `Dockerfile`. Report NeMo Guardrails bugs to the user rather than filing them.
- Known NeMo Guardrails behaviours this image works around or documents: the server always logs conversation content (hard-coded verbose mode), `--prefix` breaks single-configuration mode, the package needs `examples/bots` copied in (as NVIDIA's `build.sh` does), Chainlit writes to its app root on import even when the Chat UI is off (`CHAINLIT_APP_ROOT=/tmp`).
- Keep the image non-root with UID `10001`, and keep `HEALTHCHECK` and the OCI labels.
- When the OpenTelemetry SDK version changes, keep `OTEL_SDK_VERSION` and `OTEL_DISTRO_VERSION` matched (SDK `1.N.0` ↔ distro `0.(N+21)b0`) and compatible with the `opentelemetry-api` in NeMo Guardrails' lockfile.
- When ports, env vars, commands or the config layout change, update `README.md`, this file and `llms.txt` in the same pull request.
- The workflow must pass `actionlint` (`docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest`).
- `README.md` is also the Docker Hub description, so keep it under 25,000 characters.
