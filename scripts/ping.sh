#!/bin/sh
OUTPUT=$(codex -q "say ok" --model codex-mini-latest --approval-mode full-auto --json 2>/dev/null)
STATUS=$?
TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S%z")

if [ "$STATUS" -eq 0 ] && [ -n "$OUTPUT" ]; then
  echo "$TIMESTAMP ok"
else
  echo "$TIMESTAMP ERROR"
fi

if [ "$1" = "--debug" ]; then
  echo "$OUTPUT" | jq .
fi
