# Imported by Python at start-up through upstreamyard-logging.pth (upstreamyard image).
# NEMO_GUARDRAILS_LOG_LEVEL sets the level of the `nemoguardrails` loggers. The NeMo
# Guardrails server always enables its verbose mode, which logs every message, prompt and
# LLM answer at INFO; WARNING stops that. A .pth file is used instead of sitecustomize.py
# because opentelemetry-instrument replaces sitecustomize.
import logging
import os

_level = os.environ.get("NEMO_GUARDRAILS_LOG_LEVEL", "").strip().upper()
if _level:
    logging.getLogger("nemoguardrails").setLevel(_level)
