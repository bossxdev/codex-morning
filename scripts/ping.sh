#!/bin/sh
OUTPUT=$(codex exec "say ok" --json 2>/dev/null)
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
