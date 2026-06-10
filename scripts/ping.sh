#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
OUTPUT=$(/usr/local/bin/codex exec "say ok" --json --skip-git-repo-check 2>&1)
STATUS=$?
TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S%z")

if [ "$STATUS" -eq 0 ] && [ -n "$OUTPUT" ]; then
  echo "$TIMESTAMP ok"
else
  echo "$TIMESTAMP ERROR"
  echo "$OUTPUT"
fi

if [ "$1" = "--debug" ]; then
  echo "$OUTPUT" | grep '^{' | jq .
fi
