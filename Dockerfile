FROM node:24-alpine
RUN apk add --no-cache jq tzdata \
    && npm install -g @openai/codex@0.153.4 \
    && codex --version
COPY scripts/ /scripts/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /scripts/*.sh /entrypoint.sh \
    && mkdir -p /root/.codex \
    && chmod 700 /root/.codex
WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
