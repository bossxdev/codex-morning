# codex-morning

Runs one scheduled OpenAI Codex CLI request every five hours in a native ARM64 Docker container.

## Runtime contract

The only automated model is `gpt-5.6-luna`. Each run makes one `codex exec` request through Codex's built-in `openai` provider. No Fusion endpoint, custom base URL, API key, fallback model, alternate credential source, or automatic retry is configured.

Codex runs with `--ignore-user-config`, `--ephemeral`, `--json`, and `--skip-git-repo-check`. The login preflight receives `TERM` after 30 seconds, and request execution receives `TERM` after five minutes; either is forcibly killed after a further five seconds if it does not stop. The wrapper accepts only a complete JSONL lifecycle with numeric token usage and writes a secret-free terminal record.

The image pins `@openai/codex@0.153.4`. OpenAI documents `gpt-5.6-luna` as the exact model ID and lists it for eligible ChatGPT-authenticated Codex plans. See the [model documentation](https://developers.openai.com/api/docs/models/gpt-5.6-luna) and [ChatGPT availability documentation](https://help.openai.com/en/articles/20001354-gpt-56-in-chatgpt/).

## Schedule

Compose configures:

```text
CODEX_MORNING_CRON_SCHEDULE=0 */5 * * *
TZ=Asia/Bangkok
```

Runs occur at `00:00`, `05:00`, `10:00`, `15:00`, and `20:00` Bangkok time. Cron setup validates one five-field expression before atomically replacing root's crontab. Invalid input leaves the prior crontab unchanged and prevents daemon startup. Legacy `CLAUDE_MORNING_CRON_SCHEDULE` and `CLAUDE_MORNING_CRON_SCHEDULES` variables are rejected instead of silently changing cadence.

## Build and authenticate

```sh
docker compose build
docker compose run --rm --no-deps codex-morning login --device-auth
docker compose run --rm --no-deps codex-morning login status
```

Complete device authentication in the browser when prompted. Authentication is stored only in the project-scoped `codex-auth` Docker volume mounted at `/root/.codex`. Do not add `-T` to device login, because it disables terminal allocation.

Start production only after login succeeds:

```sh
docker compose up -d
docker compose ps
docker compose logs -f codex-morning
```

`tty: true` is intentional. Detached Codex execution can otherwise exit with empty output; OpenAI tracks this behavior in [openai/codex#19945](https://github.com/openai/codex/issues/19945).

## Authentication lifecycle

The named volume supports Codex's atomic OAuth refresh-token replacement. Reauthenticate in the same volume with:

```sh
docker compose run --rm --no-deps codex-morning login --device-auth
```

Treat the volume as live credential state. `docker compose down` preserves it. `docker compose down -v` destroys it and requires fresh device authentication. Avoid copying or inspecting its contents; reauthentication is safer than maintaining a credential archive.

## Verification

Run the no-spend regression suite, which replaces Codex with a fake binary:

```sh
tests/test.sh all
```

Available focused modes are `ping`, `cron`, and `cron-e2e`. Tests verify exact model selection, first-party provider selection, no endpoint override, one request without fallback, real status propagation, secret suppression, strict JSONL handling, cron validation, fail-closed startup, terminal allocation, and daemon behavior.

Inspect runtime state without reading credentials:

```sh
docker compose ps
docker compose exec codex-morning codex --version
docker compose exec codex-morning sh -c 'tr "\000" " " < /proc/1/cmdline; echo'
docker compose exec codex-morning cat /etc/crontabs/root
docker compose logs --tail 50 codex-morning
```

A successful record has `category=OK`, `status=0`, `requested_model=gpt-5.6-luna`, and numeric input, cached-input, and output token counts. Codex JSONL does not report an independently verifiable served-model identity, so proof is limited to the exact request argument, built-in provider, successful OAuth completion, and server acceptance.

## Audit categories

| Category | Scope |
| --- | --- |
| E001 | Repository initialization |
| E002 | Cron configuration |
| E003 | Cron daemon startup |
| E004 | Docker build |
| E005 | Container startup |
| E006 | Codex execution or response-contract failure |
| E007 | Authentication or session failure |
| E008 | Model configuration or availability failure |
| E009 | Required runtime environment or log-write failure |
| E010 | Persistent state |
| E011 | Scheduled execution |
| E012 | CI/CD validation |

These labels classify failures; they do not replace real Git, shell, Codex, Docker, or Compose exit statuses.

## Repository safety

`data/` is excluded from Git and Docker build context. `.git/` is also excluded from image builds. The service mounts no workspace, exposes no ports, and does not bind host or proxy authentication paths.
