# NeMo Guardrails with sensitive data detection (Microsoft Presidio and the spaCy
# en_core_web_lg model, ~600 MB). Adds the `sdd` extra that the base image leaves out.
ARG BASE=upstreamyard/nemo-guardrails:0.24
FROM ${BASE}
USER root
RUN pip --python /opt/venv/bin/python install --no-cache-dir \
    "presidio-analyzer>=2.2" "presidio-anonymizer>=2.2" \
    https://github.com/explosion/spacy-models/releases/download/en_core_web_lg-3.8.0/en_core_web_lg-3.8.0-py3-none-any.whl
USER 10001:10001
