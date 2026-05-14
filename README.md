# livemask-ci-cd
LiveMask CI/CD pipelines, GitHub Actions workflows, deployment automation, infrastructure as code, and multi-repo coordination scripts

## Staging Smoke

The `Staging Smoke` workflow runs on the `livemask-staging` organization runner
group. It starts `infra/docker-compose.staging.yml` and verifies the staging
entrypoint with `scripts/smoke.sh`.

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
