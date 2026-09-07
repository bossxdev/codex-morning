#!/bin/sh
# No-spend regression tests for codex-morning.
# Usage: tests/test.sh [all|ping|cron|cron-e2e]
# Runs the built image with a fake codex binary; never calls OpenAI.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE=${IMAGE:-codex-morning-test}
MODEL=gpt-5.6-luna
MODE=${1:-all}
PASS=0
FAIL=0
WORK=$(mktemp -d)
trap 'docker rm -f "cm-test-$$" "cm-e2e-$$" >/dev/null 2>&1 || :; rm -rf "$WORK"' EXIT INT TERM

say() { printf '%s\n' "$*"; }
ok() { PASS=$((PASS + 1)); say "  ok   $1"; }
no() { FAIL=$((FAIL + 1)); say "  FAIL $1${2:+: $2}"; }

build_image() {
  say "building image $IMAGE ..."
  if ! docker build -q -t "$IMAGE" "$REPO" >/dev/null; then
    say "image build failed"
    exit 1
  fi
}

make_fake_codex() {
  mkdir -p "$WORK/fake"
  cat > "$WORK/fake/codex" <<'EOF'
#!/bin/sh
umask 022
count_call() {
  _file=$1
  _count=0
  [ ! -f "$_file" ] || read -r _count < "$_file"
  _count=$((_count + 1))
  printf '%s\n' "$_count" > "$_file"
}

if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then
  count_call /fake/login_count.txt
  _rc=${FAKE_LOGIN_RC:-0}
  if [ "$_rc" -ne 0 ]; then
    printf '%s\n' 'Not logged in' >&2
    exit "$_rc"
  fi
  if [ "${FAKE_LOGIN_METHOD:-apikey}" = "chatgpt" ]; then
    printf '%s\n' 'Logged in using ChatGPT'
  else
    printf '%s\n' 'Logged in using an API key - sk-...test'
  fi
  exit 0
fi

if [ "${1:-}" != "exec" ]; then
  printf '%s\n' "unexpected fake codex command: ${1:-missing}" >&2
  exit 64
fi

count_call /fake/exec_count.txt
printf '%s\n' "$@" > /fake/exec_args.txt
env | LC_ALL=C sort > /fake/exec_env.txt

case "${FAKE_MODE:-ok}" in
  ok)
    printf '%s\n' \
      '{"type":"thread.started","thread_id":"test-thread"}' \
      '{"type":"turn.started"}' \
      '{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"ok"}}' \
      '{"type":"turn.completed","usage":{"input_tokens":5,"cached_input_tokens":0,"output_tokens":2}}'
    exit 0
    ;;
  error_event)
    printf '%s\n' \
      '{"type":"thread.started","thread_id":"test-thread"}' \
      '{"type":"turn.started"}' \
      '{"type":"error","message":"stream failed"}'
    exit 0
    ;;
  turn_failed)
    printf '%s\n' \
      '{"type":"thread.started","thread_id":"test-thread"}' \
      '{"type":"turn.started"}' \
      '{"type":"turn.failed","error":{"message":"turn failed"}}'
    exit 0
    ;;
  missing_complete)
    printf '%s\n' \
      '{"type":"thread.started","thread_id":"test-thread"}' \
      '{"type":"turn.started"}'
    exit 0
    ;;
  duplicate_complete)
    printf '%s\n' \
      '{"type":"thread.started","thread_id":"test-thread"}' \
      '{"type":"turn.started"}' \
      '{"type":"turn.completed","usage":{"input_tokens":5,"cached_input_tokens":0,"output_tokens":2}}' \
      '{"type":"turn.completed","usage":{"input_tokens":5,"cached_input_tokens":0,"output_tokens":2}}'
    exit 0
    ;;
  missing_usage)
    printf '%s\n' \
      '{"type":"thread.started","thread_id":"test-thread"}' \
      '{"type":"turn.started"}' \
      '{"type":"turn.completed","usage":{}}'
    exit 0
    ;;
  badjson) printf '%s\n' 'not-json'; exit 0 ;;
  multi_json_line)
    printf '%s\n' \
      '{"meta":"ignored"} {"type":"thread.started","thread_id":"test-thread"}' \
      '{"type":"turn.started"}' \
      '{"type":"turn.completed","usage":{"input_tokens":5,"cached_input_tokens":0,"output_tokens":2}}'
    exit 0
    ;;
  empty) exit 0 ;;
  empty_model)
    printf '%s\n' 'model gpt-5.6-luna is not available for this account' >&2
    exit 0
    ;;
  empty_auth)
    printf '%s\n' '401 Unauthorized' >&2
    exit 0
    ;;
  auth_error)
    printf '%s\n' '401 Unauthorized: key sk-test-secret' >&2
    exit 17
    ;;
  numeric_noise)
    printf '%s\n' 'rate limited; retry after 4030ms' >&2
    exit 29
    ;;
  model_unavailable)
    printf '%s\n' 'model gpt-5.6-luna is not available for this account' >&2
    exit 9
    ;;
  model_auth_conflict)
    printf '%s\n' 'model gpt-5.6-luna is not supported with ChatGPT authentication; use an API key' >&2
    exit 9
    ;;
  exit7)
    printf '%s\n' 'transport failed: sk-test-secret' >&2
    exit 7
    ;;
  exit2)
    printf '%s\n' 'unknown option' >&2
    exit 2
    ;;
  *) printf '%s\n' "unknown FAKE_MODE=${FAKE_MODE:-}" >&2; exit 65 ;;
esac
EOF
  chmod +x "$WORK/fake/codex"
}

has() { printf '%s\n' "$PR_OUT" | grep -Fq -- "$1"; }
file_count() { [ -f "$1" ] && tr -d '[:space:]' < "$1" || printf '0'; }
args_has_pair() {
  _flag=$1
  _value=$2
  [ -f "$WORK/fake/exec_args.txt" ] &&
    awk -v f="$_flag" -v v="$_value" 'prev == f && $0 == v { found = 1 } { prev = $0 } END { exit !found }' "$WORK/fake/exec_args.txt"
}
args_has_line() { [ -f "$WORK/fake/exec_args.txt" ] && grep -Fqx -- "$1" "$WORK/fake/exec_args.txt"; }

PR_OUT=""
PR_RC=0
ping_env() {
  rm -f "$WORK/fake/exec_args.txt" "$WORK/fake/exec_env.txt" \
    "$WORK/fake/exec_count.txt" "$WORK/fake/login_count.txt"
  _flags="-v $WORK/fake:/fake"
  for _kv in "$@"; do _flags="$_flags -e $_kv"; done
  PR_RC=0
  # Values supplied by this test are controlled, space-free VAR=VALUE tokens.
  # shellcheck disable=SC2086
  PR_OUT=$(docker run --rm --entrypoint /bin/sh $_flags "$IMAGE" -c \
    'cp /fake/codex /usr/local/bin/codex && exec /scripts/ping.sh' 2>&1) || PR_RC=$?
}

expect() {
  _name=$1
  _want=$2
  shift 2
  if [ "$PR_RC" -ne "$_want" ]; then
    no "$_name" "rc=$PR_RC want=$_want out=$(printf '%s' "$PR_OUT" | cut -c1-300)"
    return
  fi
  for _text in "$@"; do
    if ! has "$_text"; then
      no "$_name" "output missing '$_text': $(printf '%s' "$PR_OUT" | cut -c1-300)"
      return
    fi
  done
  ok "$_name"
}

expect_one_exec() {
  _name=$1
  [ "$(file_count "$WORK/fake/exec_count.txt")" = "1" ] && ok "$_name" ||
    no "$_name" "count=$(file_count "$WORK/fake/exec_count.txt")"
}

expect_no_exec() {
  _name=$1
  [ "$(file_count "$WORK/fake/exec_count.txt")" = "0" ] && ok "$_name" ||
    no "$_name" "count=$(file_count "$WORK/fake/exec_count.txt")"
}

t_ping() {
  say 'ping contract:'
  ping_env FAKE_MODE=ok
  expect 'success: strict completion accepted' 0 'category=OK' 'status=0' "requested_model=$MODEL" 'input_tokens=5' 'output_tokens=2'
  expect_one_exec 'success: exactly one model request'

  if args_has_pair '--model' "$MODEL"; then ok 'success: exact model argument'; else no 'success: exact model argument' "args=$(tr '\n' ' ' < "$WORK/fake/exec_args.txt" 2>/dev/null)"; fi
  if args_has_pair '--config' 'model_provider="openai"'; then ok 'success: built-in OpenAI provider override'; else no 'success: built-in OpenAI provider override'; fi
  if ! grep -Eqi 'openai_base_url|fusion|127\.0\.0\.1:(18765|8788)|claude-code-proxy|proxy[_-]?token' \
      "$WORK/fake/exec_args.txt" "$WORK/fake/exec_env.txt" 2>/dev/null; then
    ok 'success: no explicit or proxy endpoint configuration'
  else
    no 'success: no explicit or proxy endpoint configuration'
  fi

  _flags_ok=1
  for _flag in '--ignore-user-config' '--ephemeral' '--json' '--skip-git-repo-check'; do
    args_has_line "$_flag" || _flags_ok=0
  done
  [ "$_flags_ok" -eq 1 ] && ok 'success: isolation and JSONL flags present' || no 'success: isolation and JSONL flags present'

  if grep -Fq 'timeout -k 5 -s TERM 30 "$CODEX" login status' "$REPO/scripts/ping.sh"; then ok 'success: login preflight has 30-second bound and forced kill'; else no 'success: login preflight has 30-second bound and forced kill'; fi
  if grep -Fq 'timeout -k 5 -s TERM 300 "$CODEX" exec \' "$REPO/scripts/ping.sh"; then ok 'success: execution has five-minute bound and forced kill'; else no 'success: execution has five-minute bound and forced kill'; fi

  _models=$(grep -E '^gpt-' "$WORK/fake/exec_args.txt" 2>/dev/null || true)
  [ "$_models" = "$MODEL" ] && ok 'success: no alternate model argument' || no 'success: no alternate model argument' "models=$_models"

  ping_env FAKE_MODE=ok CODEX_MORNING_LOG_FILE=/proc/1/no-such-dir/log
  expect 'log write failure: reported as E009' 1 'category=E009' 'status=1'
  expect_one_exec 'log write failure: no retry'

  ping_env FAKE_MODE=ok FAKE_LOGIN_RC=23
  expect 'login failure: status preserved' 23 'category=E007' 'status=23' 'authentication'
  expect_no_exec 'login failure: model not invoked'

  ping_env FAKE_MODE=ok FAKE_LOGIN_METHOD=chatgpt
  expect 'ChatGPT auth: successful login proceeds' 0 'category=OK' 'status=0' "requested_model=$MODEL"
  expect_one_exec 'ChatGPT auth: exactly one model request'

  ping_env FAKE_MODE=model_unavailable
  expect 'model unavailable: status preserved' 9 'category=E008' 'status=9' "requested_model=$MODEL"
  expect_one_exec 'model unavailable: no retry or fallback'

  ping_env FAKE_MODE=model_auth_conflict
  expect 'model/auth overlap: classified as model unavailable' 9 'category=E008' 'status=9' "requested_model=$MODEL"
  expect_one_exec 'model/auth overlap: no retry or fallback'

  ping_env FAKE_MODE=auth_error
  expect 'execution auth error: status preserved' 17 'category=E007' 'status=17'
  if has 'sk-test-secret'; then no 'execution auth error: secret suppressed'; else ok 'execution auth error: secret suppressed'; fi

  ping_env FAKE_MODE=numeric_noise
  expect 'unrelated auth-code digits: remain generic execution failure' 29 'category=E006' 'status=29'
  expect_one_exec 'unrelated auth-code digits: no retry'

  ping_env FAKE_MODE=exit7
  expect 'execution failure: status preserved' 7 'category=E006' 'status=7' 'codex_status=7'
  if has 'sk-test-secret'; then no 'execution failure: raw stderr suppressed'; else ok 'execution failure: raw stderr suppressed'; fi

  ping_env FAKE_MODE=exit2
  expect 'CLI usage failure: status preserved' 2 'category=E006' 'status=2' 'codex_status=2'

  for _mode in badjson multi_json_line empty error_event turn_failed missing_complete duplicate_complete missing_usage; do
    ping_env "FAKE_MODE=$_mode"
    expect "response $_mode: rejected" 1 'category=E006' 'status=1'
    expect_one_exec "response $_mode: no retry"
  done

  ping_env FAKE_MODE=empty_model
  expect 'empty model response: classified as model unavailable' 1 'category=E008' 'status=1' 'codex_status=0'
  expect_one_exec 'empty model response: no retry or fallback'

  ping_env FAKE_MODE=empty_auth
  expect 'empty auth response: classified as authentication failure' 1 'category=E007' 'status=1' 'codex_status=0'
  expect_one_exec 'empty auth response: no retry or fallback'
}

CR_OUT=""
cron_env() {
  _schedule=$1
  shift
  CR_OUT=$(docker run --rm --entrypoint /bin/sh \
    -e "CODEX_MORNING_CRON_SCHEDULE=$_schedule" "$@" "$IMAGE" -c '
      printf "%s\n" "# sentinel" > /etc/crontabs/root
      cp /etc/crontabs/root /tmp/before
      /scripts/setup-cron.sh > /tmp/setup.out 2>&1
      rc=$?
      cat /tmp/setup.out
      cmp -s /tmp/before /etc/crontabs/root && unchanged=1 || unchanged=0
      printf "SETUP_RC=%s UNCHANGED=%s\n" "$rc" "$unchanged"
      printf "%s\n" "---crontab---"
      cat /etc/crontabs/root
    ' 2>&1)
}

cron_setup_rc() { printf '%s\n' "$CR_OUT" | sed -n 's/.*SETUP_RC=\([0-9][0-9]*\).*/\1/p' | tail -1; }
cron_unchanged() { printf '%s\n' "$CR_OUT" | grep -Fq 'UNCHANGED=1'; }
cron_has_line() { printf '%s\n' "$CR_OUT" | grep -Fqx -- "$1"; }
cron_ping_lines() { printf '%s\n' "$CR_OUT" | grep -c '/scripts/ping.sh'; }

t_cron() {
  say 'compose contract:'
  if docker compose -f "$REPO/docker-compose.yml" --project-directory "$REPO" config --format json |
      jq -e '.services["codex-morning"].tty == true' >/dev/null; then
    ok 'detached daemon retains controlling TTY'
  else
    no 'detached daemon retains controlling TTY'
  fi

  say 'cron contract:'
  _job='0 */5 * * * /scripts/ping.sh >> /proc/1/fd/1 2>&1'
  cron_env '0 */5 * * *'
  if [ "$(cron_setup_rc)" = '0' ] && [ "$(cron_ping_lines)" = '1' ] && cron_has_line "$_job"; then
    ok 'valid schedule installs exact one-line job'
  else
    no 'valid schedule installs exact one-line job' "$(printf '%s' "$CR_OUT" | tail -5 | tr '\n' '|')"
  fi

  cron_env '* * * * *'
  [ "$(cron_setup_rc)" = '0' ] && cron_has_line '* * * * * /scripts/ping.sh >> /proc/1/fd/1 2>&1' &&
    ok 'accelerated valid schedule accepted' || no 'accelerated valid schedule accepted'

  for _legacy in CLAUDE_MORNING_CRON_SCHEDULE CLAUDE_MORNING_CRON_SCHEDULES; do
    cron_env '0 */5 * * *' -e "$_legacy=0 8 * * *"
    if [ -n "$(cron_setup_rc)" ] && [ "$(cron_setup_rc)" != '0' ] && cron_unchanged; then
      ok "legacy schedule variable rejected: $_legacy"
    else
      no "legacy schedule variable rejected: $_legacy" "rc=$(cron_setup_rc)"
    fi
  done

  for _bad in \
    '0 */5 * *' \
    '60 */5 * * *' \
    '0 0 * * *,0 5 * * *' \
    '* * * * * rm -rf /' \
    '0 */5 * * *; reboot' \
    'banana' \
    '' \
    "$(printf '0 */5 * * *\n* * * * * touch /pwn')"
  do
    cron_env "$_bad"
    if [ -n "$(cron_setup_rc)" ] && [ "$(cron_setup_rc)" != '0' ] && cron_unchanged; then
      ok "invalid schedule rejected and unchanged: $(printf '%s' "$_bad" | tr '\n' ' ')"
    else
      no "invalid schedule rejected and unchanged: $(printf '%s' "$_bad" | tr '\n' ' ')" "rc=$(cron_setup_rc)"
    fi
  done

  say 'entrypoint daemon failure:'
  for _bad in '60 * * * *' 'banana'; do
    _name="cm-test-$$"
    docker rm -f "$_name" >/dev/null 2>&1 || :
    _rc=0
    timeout -s KILL 30 docker run --rm --name "$_name" \
      -e "CODEX_MORNING_CRON_SCHEDULE=$_bad" "$IMAGE" daemon >/dev/null 2>&1 || _rc=$?
    docker rm -f "$_name" >/dev/null 2>&1 || :
    [ "$_rc" -eq 1 ] && ok "malformed cron exits container 1: $_bad" || no "malformed cron exits container 1: $_bad" "rc=$_rc"
  done
}

t_cron_e2e() {
  say 'cron end-to-end (accelerated, fake Codex):'
  rm -f "$WORK/fake/exec_args.txt" "$WORK/fake/exec_env.txt" \
    "$WORK/fake/exec_count.txt" "$WORK/fake/login_count.txt"
  _name="cm-e2e-$$"
  docker rm -f "$_name" >/dev/null 2>&1 || :
  _cid=$(docker run -d --name "$_name" \
    -e 'CODEX_MORNING_CRON_SCHEDULE=* * * * *' \
    -e FAKE_MODE=ok \
    -v "$WORK/fake:/fake" \
    --entrypoint /bin/sh \
    "$IMAGE" -c 'cp /fake/codex /usr/local/bin/codex && exec /entrypoint.sh daemon') || {
      no 'e2e: container start' 'docker run failed'
      return
    }

  _fired=0
  _i=0
  while [ "$_i" -lt 75 ]; do
    if docker exec "$_cid" grep -Fq 'category=OK' /var/log/codex-ping.log 2>/dev/null; then _fired=1; break; fi
    sleep 1
    _i=$((_i + 1))
  done
  if [ "$_fired" -ne 1 ]; then
    no 'e2e: cron completed within 75s' 'success log absent'
    docker rm -f "$_cid" >/dev/null 2>&1 || :
    return
  fi
  ok 'e2e: cron completed within 75s'

  [ "$(file_count "$WORK/fake/exec_count.txt")" = '1' ] && ok 'e2e: exactly one request observed' || no 'e2e: exactly one request observed'
  args_has_pair '--model' "$MODEL" && ok 'e2e: exact model argument' || no 'e2e: exact model argument'

  _running=$(docker inspect -f '{{.State.Running}}' "$_cid" 2>/dev/null)
  [ "$_running" = 'true' ] && ok 'e2e: daemon remains running' || no 'e2e: daemon remains running' "running=$_running"

  if docker logs "$_cid" 2>&1 | grep -Fq 'category=OK'; then
    ok 'e2e: Docker log records success'
  else
    no 'e2e: Docker log records success'
  fi
  docker rm -f "$_cid" >/dev/null 2>&1 || :
}

case "$MODE" in
  ping) build_image; make_fake_codex; t_ping ;;
  cron) build_image; t_cron ;;
  cron-e2e) build_image; make_fake_codex; t_cron_e2e ;;
  all) build_image; make_fake_codex; t_ping; t_cron; t_cron_e2e ;;
  *) say "unknown mode: $MODE (use all|ping|cron|cron-e2e)"; exit 2 ;;
esac

say '----------------------------------------'
say "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
