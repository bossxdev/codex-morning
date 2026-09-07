#!/bin/sh
set -u

if [ "${1:-}" = 'daemon' ]; then
  /scripts/setup-cron.sh
  SETUP_RC=$?
  if [ "$SETUP_RC" -ne 0 ]; then
    printf 'entrypoint: category=E002 status=%s cron setup failed; refusing E003 daemon startup\n' "$SETUP_RC" >&2
    exit "$SETUP_RC"
  fi
  exec crond -f -l 8
fi

exec /usr/local/bin/codex "$@"
