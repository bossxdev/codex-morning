FROM node:24-alpine
RUN apk add --no-cache jq tzdata && npm install -g @openai/codex
COPY scripts/ /scripts/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /scripts/*.sh /entrypoint.sh
WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
