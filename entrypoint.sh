#!/bin/sh
if [ "$TZ" != "" ]; then
  echo "Timezone: $TZ"
fi
if [ "$1" = "daemon" ]; then
  /scripts/setup-cron.sh
  exec crond -f -l 8
else
  exec codex "$@"
fi
