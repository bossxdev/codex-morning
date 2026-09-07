#!/bin/sh
# Execute one scheduled Codex request with a fixed model and first-party routing.
set -u

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MODEL='gpt-5.6-luna'
PROVIDER='openai'
CODEX='/usr/local/bin/codex'
LOG_FILE=${CODEX_MORNING_LOG_FILE:-/var/log/codex-ping.log}
TS=$(date +'%Y-%m-%dT%H:%M:%S%z')
umask 077

TMP_BASE=${TMPDIR:-/tmp}/codex-ping.$$
LOGIN_OUT=${TMP_BASE}.login.out
LOGIN_ERR=${TMP_BASE}.login.err
OUT_FILE=${TMP_BASE}.out
ERR_FILE=${TMP_BASE}.err
trap 'rm -f "$LOGIN_OUT" "$LOGIN_ERR" "$OUT_FILE" "$ERR_FILE"' EXIT INT TERM

emit() {
  _category=$1
  _status=$2
  _detail=$3
  _line="$TS category=$_category status=$_status $_detail"
  printf '%s\n' "$_line"
  if ! printf '%s\n' "$_line" >> "$LOG_FILE"; then
    printf '%s category=E009 status=1 error="cannot append Codex log"\n' "$TS" >&2
    return 1
  fi
}

classify_failure() {
  if grep -Eqi 'unknown model|model.*(not found|not available|unavailable|unsupported|not supported|retired)|access[^[:alnum:]]+to[^[:alnum:]]+.*model|model.*access' "$OUT_FILE" "$ERR_FILE" 2>/dev/null; then
    printf '%s\n' E008
  elif grep -Eqi '(^|[^0-9])(401|403)([^0-9]|$)|unauthori[sz]ed|authentication|not logged in|log in|api[ -]?key' "$OUT_FILE" "$ERR_FILE" 2>/dev/null; then
    printf '%s\n' E007
  else
    printf '%s\n' E006
  fi
}

LOGIN_RC=0
timeout -k 5 -s TERM 30 "$CODEX" login status > "$LOGIN_OUT" 2> "$LOGIN_ERR" || LOGIN_RC=$?
if [ "$LOGIN_RC" -ne 0 ]; then
  emit E007 "$LOGIN_RC" 'reason=authentication_status_failed' || :
  exit "$LOGIN_RC"
fi

CODEX_RC=0
timeout -k 5 -s TERM 300 "$CODEX" exec \
  --model "$MODEL" \
  --config "model_provider=\"$PROVIDER\"" \
  --ignore-user-config \
  --ephemeral \
  --json \
  --skip-git-repo-check \
  'say ok' > "$OUT_FILE" 2> "$ERR_FILE" || CODEX_RC=$?

if [ "$CODEX_RC" -ne 0 ]; then
  CATEGORY=$(classify_failure)
  case "$CATEGORY" in
    E007)
      emit E007 "$CODEX_RC" "codex_status=$CODEX_RC reason=authentication_failed requested_model=$MODEL" || :
      ;;
    E008)
      emit E008 "$CODEX_RC" "codex_status=$CODEX_RC reason=model_unavailable requested_model=$MODEL" || :
      ;;
    *)
      emit E006 "$CODEX_RC" "codex_status=$CODEX_RC reason=codex_execution_failed requested_model=$MODEL" || :
      ;;
  esac
  exit "$CODEX_RC"
fi

if [ ! -s "$OUT_FILE" ]; then
  CATEGORY=$(classify_failure)
  emit "$CATEGORY" 1 "codex_status=0 reason=response_contract_empty requested_model=$MODEL" || :
  exit 1
fi

# JSONL requires one complete JSON object on every nonempty physical line.
if grep -q '^[[:space:]]*$' "$OUT_FILE"; then
  emit E006 1 "reason=response_contract_blank_line requested_model=$MODEL" || :
  exit 1
fi
_JSONL_OK=1
while IFS= read -r _json_line || [ -n "$_json_line" ]; do
  if ! printf '%s\n' "$_json_line" | jq -s -e '(length == 1) and ((.[0] | type) == "object")' >/dev/null 2>&1; then
    _JSONL_OK=0
    break
  fi
done < "$OUT_FILE"
if [ "$_JSONL_OK" -ne 1 ]; then
  emit E006 1 "reason=response_contract_invalid_jsonl requested_model=$MODEL" || :
  exit 1
fi

if ! jq -s -e '
  (length > 0) and
  (([.[] | select(.type == "thread.started")] | length) == 1) and
  (([.[] | select(.type == "turn.started")] | length) == 1) and
  (([.[] | select(.type == "turn.completed")] | length) == 1) and
  (([.[] | select(.type == "error" or .type == "turn.failed")] | length) == 0) and
  (.[-1].type == "turn.completed") and
  (([.[] | select(.type == "turn.completed")][0].usage.input_tokens | type) == "number") and
  (([.[] | select(.type == "turn.completed")][0].usage.cached_input_tokens | type) == "number") and
  (([.[] | select(.type == "turn.completed")][0].usage.output_tokens | type) == "number") and
  ([.[] | select(.type == "turn.completed")][0].usage.input_tokens >= 0) and
  ([.[] | select(.type == "turn.completed")][0].usage.cached_input_tokens >= 0) and
  ([.[] | select(.type == "turn.completed")][0].usage.output_tokens >= 0)
' "$OUT_FILE" >/dev/null 2>&1; then
  CATEGORY=$(classify_failure)
  emit "$CATEGORY" 1 "reason=response_contract_failed requested_model=$MODEL" || :
  exit 1
fi

INPUT_TOKENS=$(jq -sr '[.[] | select(.type == "turn.completed")][0].usage.input_tokens' "$OUT_FILE")
CACHED_INPUT_TOKENS=$(jq -sr '[.[] | select(.type == "turn.completed")][0].usage.cached_input_tokens' "$OUT_FILE")
OUTPUT_TOKENS=$(jq -sr '[.[] | select(.type == "turn.completed")][0].usage.output_tokens' "$OUT_FILE")

if ! emit OK 0 "requested_model=$MODEL input_tokens=$INPUT_TOKENS cached_input_tokens=$CACHED_INPUT_TOKENS output_tokens=$OUTPUT_TOKENS"; then
  exit 1
fi

if [ "${1:-}" = '--debug' ]; then
  jq -s . "$OUT_FILE"
fi
exit 0
