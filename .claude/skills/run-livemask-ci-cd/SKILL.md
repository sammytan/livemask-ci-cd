---
name: run-livemask-ci-cd
description: Run, validate, and smoke-test LiveMask CI/CD scripts, workflows, and local Docker infrastructure.
---

All paths are relative to the repo root (`livemask-ci-cd/`).

## What this is

LiveMask CI/CD — a collection of GitHub Actions workflows, Docker Compose
infrastructure, and ~70 shell scripts that orchestrate build, deploy, smoke,
merge-guard, and task-assignment automation across the LiveMask multi-repo
project.

The driver (`.claude/skills/run-livemask-ci-cd/driver.sh`) provides a unified
interface for the three things an agent actually does here:

1. **Validate** — YAML parse, workflow contract checks, shell syntax, Docker Compose configs.
2. **Infra** — start/stop/status of the local Docker Compose runtime.
3. **Smoke** — run individual smoke scripts against a running backend.

## Prerequisites

```bash
# macOS
brew install ruby shellcheck

# Ubuntu
sudo apt-get install -y ruby shellcheck docker-ce-cli
```

The driver also needs `docker` (for compose config validation and infra
commands) and `python3` (for JSON formatting in smoke output).

## Validate (agent path)

The primary development loop: make a change to a script or workflow, then run
the relevant validator.

```bash
# Full suite — run after any change touching scripts or workflows.
bash .claude/skills/run-livemask-ci-cd/driver.sh validate-all

# Individual validators:
bash .claude/skills/run-livemask-ci-cd/driver.sh validate-yaml        # Parse every YAML file.
bash .claude/skills/run-livemask-ci-cd/driver.sh validate-workflows   # Check workflow name/trigger/job contracts.
bash .claude/skills/run-livemask-ci-cd/driver.sh validate-compose     # Validate docker-compose.{local,staging}.yml.
bash .claude/skills/run-livemask-ci-cd/driver.sh validate-shell       # bash -n on all scripts/*.sh.
bash .claude/skills/run-livemask-ci-cd/driver.sh validate-dev-ref     # Check that service refs are 'dev'.
```

The driver exits 0 when all checks pass, non-zero when any fail. Output uses
`[PASS]` / `[FAIL]` tags for scripting.

## Lint a single script

```bash
shellcheck scripts/some-smoke.sh
# or via the driver:
bash .claude/skills/run-livemask-ci-cd/driver.sh lint scripts/some-smoke.sh
```

## Infra (Docker Compose)

The local dev runtime is defined in `infra/docker-compose.local.yml`. It
depends on sibling repos (`../livemask-backend`, `../livemask-admin`, etc.)
being present for source mounts.

```bash
# Start just postgres + redis (no sibling repos needed):
bash .claude/skills/run-livemask-ci-cd/driver.sh infra-up postgres,redis

# Start the full local stack:
bash scripts/local-dev.sh start

# Status / logs:
bash .claude/skills/run-livemask-ci-cd/driver.sh infra-status
bash scripts/local-dev.sh logs --services backend

# Stop (only when explicitly asked):
bash .claude/skills/run-livemask-ci-cd/driver.sh infra-down
```

The local dev runtime is persistent by default. Do NOT run `stop`/`down`/`restart`
unless the user explicitly requests it.

Fixed local ports:
| Service   | URL                     |
|-----------|-------------------------|
| Backend   | http://127.0.0.1:18080  |
| Admin     | http://127.0.0.1:3001   |
| Website   | http://127.0.0.1:3002   |
| App Web   | http://127.0.0.1:3003   |
| NodeAgent | http://127.0.0.1:19090  |
| JobSvc    | http://127.0.0.1:19191  |
| Postgres  | 127.0.0.1:15432         |
| Redis     | 127.0.0.1:16379         |

## Smokes

Each smoke script targets a specific subsystem. They expect a running backend
at `http://127.0.0.1:${LIVEMASK_BACKEND_HTTP_PORT:-18080}`.

```bash
# List available smoke scripts:
bash .claude/skills/run-livemask-ci-cd/driver.sh smoke list

# Run one:
bash .claude/skills/run-livemask-ci-cd/driver.sh smoke smoke             # main staging smoke
bash .claude/skills/run-livemask-ci-cd/driver.sh smoke api-smoke         # API smoke

# Or run directly:
LIVEMASK_BACKEND_HTTP_PORT=18080 bash scripts/smoke.sh
```

Smoke scripts that hit the NodeAgent config endpoint expect HMAC-signed
requests — the smoke handles the 403 gracefully and falls back to the admin
config list.

## Run (human path)

```bash
bash scripts/local-dev.sh start
# → opens long-lived local runtime in Docker
bash scripts/local-dev.sh status
# Ctrl-C does not stop it (persistent by design).
```

The human path is useful for checking the local dev runtime state, but
useless for headless/CI environments. Use the driver's `validate-*` and
`infra-*` commands for programmatic interaction.

## Gotchas

- **Ruby YAML parser is sensitive.** The system Ruby on macOS (2.6) rejects
  some YAML constructs that newer Psych versions accept. YAML errors in
  worktree/node_modules files are non-fatal to validation — they are
  external dependencies, not this repo's files.
- **`2>/dev/null` on `for` loops fails on macOS bash 3.2.** The driver
  works around this by pre-building file lists. Don't use that pattern in
  new scripts.
- **Smoke scripts use the staging compose file by default**
  (`infra/docker-compose.staging.yml`). Set `COMPOSE_FILE` or
  `LIVEMASK_BACKEND_HTTP_PORT` to redirect to the local runtime.
- **The local runtime is persistent.** The README and cursor rules both
  forbid stop/restart/cleanup without explicit user request. If services
  are already running, `infra-up` is a no-op for those containers.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ruby: No such file or directory` | `brew install ruby` (macOS) or `apt-get install -y ruby` (Linux) |
| `shellcheck: command not found` | `brew install shellcheck` |
| `docker: command not found` | Install Docker Desktop (macOS) or `apt-get install -y docker-ce-cli` |
| `Cannot connect to the Docker daemon` | Start Docker Desktop or `sudo systemctl start docker` |
| `compose config` fails with "no such service" | Check that env vars (`LIVEMASK_BACKEND_HTTP_PORT`, etc.) are set |
| Backend health check returns empty | Wait for `docker compose up -d --wait` to report healthy |
| Smoke script fails on Config Center Redis check | Expected when running against the local runtime — the smoke's `docker exec redis-cli` command targets a container name from the staging compose file |
