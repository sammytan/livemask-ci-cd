# livemask-ci-cd
LiveMask CI/CD pipelines, GitHub Actions workflows, deployment automation, infrastructure as code, and multi-repo coordination scripts

## Local Dev Runtime

Use `scripts/local-dev.sh` for the long-lived local development runtime. It
wraps `scripts/runtime.sh` with the local compose stack (`livemask-local`) and
defaults to all local services.

The local dev ports are fixed by `scripts/local-dev.sh` so every Cursor/Codex
window uses the same entrypoints:

| Service | URL / port |
| --- | --- |
| Backend | `http://127.0.0.1:18080` |
| Admin | `http://127.0.0.1:3001` |
| Website | `http://127.0.0.1:3002` |
| App Web | `http://127.0.0.1:3003` |
| NodeAgent | `http://127.0.0.1:19090` |
| Postgres | `127.0.0.1:15432` |
| Redis | `127.0.0.1:16379` |

```bash
bash scripts/local-dev.sh start
bash scripts/local-dev.sh status
```

After a repo task is completed and pushed, refresh the running local service
without stopping the whole local stack:

```bash
bash scripts/local-dev.sh sync --services backend
bash scripts/local-dev.sh sync --services backend,nodeagent
bash scripts/local-dev.sh sync --services admin,website
bash scripts/local-dev.sh sync --services all
```

`sync` pulls clean sibling repos with `git pull --ff-only origin dev` and then
recreates only the selected Docker services with `docker compose up -d`. It does
not run `docker compose down`. If a repo has local/Cursor changes, the pull is
skipped so those changes are not overwritten.

Use this after any repo task that changes a locally running service:

| Repo | Local service refresh |
| --- | --- |
| `livemask-backend` | `bash scripts/local-dev.sh sync --services backend` |
| `livemask-nodeagent` | `bash scripts/local-dev.sh sync --services nodeagent` |
| `livemask-job-service` | `bash scripts/local-dev.sh sync --services job-service` |
| `livemask-admin` | `bash scripts/local-dev.sh sync --services admin` |
| `livemask-website` | `bash scripts/local-dev.sh sync --services website` |
| multiple services | `bash scripts/local-dev.sh sync --services backend,admin,website,nodeagent,job-service` |

`livemask-app` is not managed by Docker. Use `livemask-app/scripts/local-app.sh`
for Flutter build/run refresh.

## Dev Merge Guard

All completed task branches must be merged into `dev` through the guarded merge
script. Do not run ad hoc batch merges such as `for branch in task/*; do git
merge ...; done`.

Example:

```bash
bash scripts/dev-merge-guard.sh \
  --repo ../livemask-admin \
  --task-branch task/TASK-ADMIN-EXAMPLE-001 \
  --task-id TASK-ADMIN-EXAMPLE-001 \
  --push
```

The guard is fail-closed:

- dirty worktree: stop
- merge/rebase/cherry-pick in progress: stop
- missing `origin/dev`: stop
- task branch without remote backup: stop
- merge conflict: abort merge and stop
- validation failure: stop before push
- no `--push`: stop after integration validation

The guard creates a `rescue/*` branch from `origin/dev`, tests the merge on an
`integration/*` branch, re-runs validation on `dev`, and only then pushes
`origin/dev`.

## Cursor Worker Continuation

After a Cursor task is completed, merged to `dev`, validated, pushed, and
reported to `livemask-docs`, a worker may ask for the next docs-assigned task
with:

```bash
bash scripts/accept-next-task.sh \
  --repo livemask-backend \
  --previous-task-id TASK-BACKEND-EXAMPLE-001
```

The script is fail-closed. It refuses to continue when the local worktree is
dirty, the previous task report is not confirmed by docs, the repo assignment
does not match, the lease expired, the task is marked manual-only, the worker
chain/runtime limit is reached, or docs cannot be fetched within the retry
budget.

By default, the worker waits up to 30 minutes for a docs assignment. If no
eligible task is received before that timeout, it stops with exit code `10` and
prints a `Cursor worker stop report` containing the repo, docs source, waited
seconds, timeout seconds, total repo tasks, and blocked-task reasons.

Exit codes are part of the automation contract:

| Code | Meaning |
| --- | --- |
| `0` | next task accepted; read the generated brief |
| `10` | no eligible task for this repo |
| `20` | local chain/runtime guard blocked continuation |
| `30` | dirty worktree |
| `40` | repo/task mismatch |
| `50` | previous report is pending or not accepted |
| `60` | validation guard failed |
| `70` | docs fetch timeout |
| `80` | lease expired |
| `90` | manual dispatch required |
| `100` | script/config error |

Runtime repos can call
`.github/workflows/reusable-cursor-worker-continuation.yml` to reuse the same
guard logic and upload the generated brief/state artifact. The workflow reports
safe stop outcomes (`idle_no_task`, `blocked`, `report_pending`, `lease_expired`,
`manual_required`) as successful workflow outcomes so the caller can decide
whether to keep or stop the Cursor window without creating noisy failed checks.

## Branch Protection

Use `scripts/apply-branch-protection.sh` to apply the baseline GitHub branch
protection for LiveMask `dev` and `main` branches:

```bash
DRY_RUN=true bash scripts/apply-branch-protection.sh
bash scripts/apply-branch-protection.sh
```

The baseline protection disallows force pushes and branch deletion. It does not
yet require named status checks because some repos still use different check
names; tighten required checks once each repo has stable green CI on `dev`.

The local runtime is persistent by default. Do not run `stop`, `down`,
`restart`, `docker compose down`, or process-kill cleanup unless the user
explicitly asks for that action. Staging smoke tests must use their isolated
staging compose stack and must not affect `livemask-local`.

## Staging Smoke

The `Staging Smoke` workflow runs on the `livemask-staging` organization runner
group. It starts `infra/docker-compose.staging.yml` and verifies the staging
entrypoint with `scripts/smoke.sh`.

Smoke validation is **dev-only**. Do not run acceptance smoke from `task/*`,
`codex/*`, or any other feature branch. A task branch can run local/unit
prechecks, but final CI/CD evidence must come after the task branch is merged
into `dev`, pushed to `origin/dev`, and rebuilt from `dev`.

NodeAgent-protocol smoke rules (mandatory for local runtime):

- `scripts/protocol-endpoint-smoke.sh` and `scripts/protocol-capability-smoke.sh`
  must use an existing real node (default node name: `local-nodeagent`).
- The scripts no longer create virtual smoke nodes for protocol validation.
- Override only when needed with `LIVEMASK_SMOKE_NODE_ID` and optionally
  `LIVEMASK_SMOKE_NODE_NAME`.
- If a new node is required, provision it as a **real NodeAgent container**
  (for example by scaling `nodeagent` service in local compose), let it register,
  run smoke, then remove/scale-down after test. Do not use fake DB-only nodes.
- Each run must include backend + nodeagent container log sanity checks.

The workflow and compose defaults set service refs to `dev`. `scripts/validate-dev-ref.sh`
fails fast if a smoke run tries to use a non-`dev` service ref.

Current default smoke target:

```text
http://127.0.0.1:18080
```

Override when needed:

```bash
LIVEMASK_SMOKE_HTTP_PORT=18081 bash scripts/smoke.sh
LIVEMASK_SMOKE_URL=https://staging.example.com bash scripts/smoke.sh
```

Replace the placeholder nginx service with real LiveMask backend, admin,
website, app support services, Redis, and database services as those deployment
artifacts become available.
