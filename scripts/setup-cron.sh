#!/bin/sh
# Validate one five-field schedule, then replace root's crontab atomically.
set -u
set -f

SCHEDULE=${CODEX_MORNING_CRON_SCHEDULE-0 */5 * * *}
CRONDIR=/etc/crontabs
CRONFILE=$CRONDIR/root
PROBE_DIR=$(mktemp -d)
PROBE_LOG=${PROBE_DIR}.log
NEW=''
trap 'rm -rf "$PROBE_DIR"; rm -f "$PROBE_LOG"; [ -z "$NEW" ] || rm -f "$NEW"' EXIT INT TERM

fail() {
  printf '%s\n' "setup-cron: $1" >&2
  exit 1
}

if [ "${CLAUDE_MORNING_CRON_SCHEDULE+x}" = x ] ||
   [ "${CLAUDE_MORNING_CRON_SCHEDULES+x}" = x ]; then
  fail 'legacy CLAUDE_MORNING_CRON_SCHEDULE variables are unsupported; use CODEX_MORNING_CRON_SCHEDULE'
fi

[ -n "$SCHEDULE" ] || fail 'CODEX_MORNING_CRON_SCHEDULE must not be empty'
case "$SCHEDULE" in
  *'
'*) fail 'CODEX_MORNING_CRON_SCHEDULE must be one line' ;;
esac
CR=$(printf '\r')
case "$SCHEDULE" in
  *"$CR"*) fail 'CODEX_MORNING_CRON_SCHEDULE must not contain carriage returns' ;;
esac

printf '%s' "$SCHEDULE" | grep -Eq '^[0-9*/.,[:space:]-]+$' ||
  fail "invalid characters in schedule '$SCHEDULE'"

set -- $SCHEDULE
[ "$#" -eq 5 ] || fail "expected 5 cron fields, got $#"
NORMALIZED="$1 $2 $3 $4 $5"

command -v crond >/dev/null 2>&1 || fail 'crond is not installed'
{
  printf '%s /bin/true\n' "$NORMALIZED"
  printf '* * * * * /bin/true # CODEX_PROBE_END\n'
} > "$PROBE_DIR/root" || fail 'cannot create parser probe'
chmod 600 "$PROBE_DIR/root" || fail 'cannot secure parser probe'
crond -f -d 0 -c "$PROBE_DIR" > "$PROBE_LOG" 2>&1 &
CROND_PID=$!
PROBE_READY=0
PROBE_WAIT=0
while [ "$PROBE_WAIT" -lt 50 ]; do
  if grep -Fq 'CODEX_PROBE_END' "$PROBE_LOG"; then
    PROBE_READY=1
    break
  fi
  kill -0 "$CROND_PID" 2>/dev/null || break
  sleep .1
  PROBE_WAIT=$((PROBE_WAIT + 1))
done
kill "$CROND_PID" 2>/dev/null || :
wait "$CROND_PID" 2>/dev/null || :
[ "$PROBE_READY" -eq 1 ] || fail 'crond parser probe did not complete'
if grep -Fqi 'parse error' "$PROBE_LOG"; then
  fail "crond rejected schedule '$NORMALIZED'"
fi

[ -d "$CRONDIR" ] || mkdir -p "$CRONDIR" || fail "cannot create $CRONDIR"
NEW=$(mktemp "$CRONFILE.tmp.XXXXXX") || fail 'cannot create crontab candidate'
printf '%s /scripts/ping.sh >> /proc/1/fd/1 2>&1\n' "$NORMALIZED" > "$NEW" ||
  fail 'cannot write crontab candidate'
chmod 600 "$NEW" || fail 'cannot secure crontab candidate'
mv -f "$NEW" "$CRONFILE" || fail 'cannot install crontab candidate'
NEW=''
printf '%s\n' "Cron scheduled: $NORMALIZED" >&2
