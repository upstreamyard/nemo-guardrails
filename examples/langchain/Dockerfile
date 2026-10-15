# NeMo Guardrails with LangChain providers that aren't OpenAI-compatible (here: Anthropic).
# langchain-community is needed too, although NVIDIA's docs only name langchain and the
# provider package. Set the provider's API key, e.g. ANTHROPIC_API_KEY.
ARG BASE=upstreamyard/nemo-guardrails:0.24
FROM ${BASE}
USER root
RUN pip --python /opt/venv/bin/python install --no-cache-dir langchain langchain-community langchain-anthropic
USER 10001:10001
ENV NEMOGUARDRAILS_LLM_FRAMEWORK=langchain
