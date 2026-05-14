#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
SMOKE_URL="${LIVEMASK_SMOKE_URL:-http://127.0.0.1:${LIVEMASK_SMOKE_HTTP_PORT:-18080}}"

echo "Smoke target: ${SMOKE_URL}"
docker compose -f "${COMPOSE_FILE}" ps

for attempt in $(seq 1 30); do
  if curl -fsS "${SMOKE_URL}" >/dev/null; then
    echo "Smoke check passed on attempt ${attempt}"
    exit 0
  fi

  echo "Waiting for staging smoke target... attempt ${attempt}/30"
  sleep 2
done

echo "Smoke check failed: ${SMOKE_URL} did not become healthy"
docker compose -f "${COMPOSE_FILE}" logs --tail=100
exit 1
