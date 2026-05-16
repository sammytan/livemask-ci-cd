#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
HEALTH_URL="http://127.0.0.1:${BACKEND_HTTP_PORT}/api/v1/health"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Smoke: Health API ==="
echo "Target: ${HEALTH_URL}"

# Wait for backend to be ready (up to 60s)
for attempt in $(seq 1 30); do
  response=$(curl -sS --max-time 3 "${HEALTH_URL}" 2>/dev/null || true)
  if [[ -n "$response" ]]; then
    echo "Backend responded on attempt ${attempt}"
    break
  fi
  echo "Waiting for backend... attempt ${attempt}/30"
  sleep 2
done

echo ""
echo "=== Health Response ==="
echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"

# Parse response fields
status=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "")
db=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['db_connected'])" 2>/dev/null || echo "")
redis=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['redis_connected'])" 2>/dev/null || echo "")

failed=0

if [[ "$status" != "ok" ]]; then
  echo "FAIL: status=\"${status}\", expected \"ok\""
  failed=1
fi

if [[ "$db" != "True" ]]; then
  echo "FAIL: db_connected=\"${db}\", expected True"
  failed=1
fi

if [[ "$redis" != "True" ]]; then
  echo "FAIL: redis_connected=\"${redis}\", expected True"
  failed=1
fi

if [[ "$failed" -eq 1 ]]; then
  echo ""
  echo "=== Diagnostic Info ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo ""
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  echo ""
  echo "--- docker compose logs postgres (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs postgres --tail=50 2>/dev/null || true
  echo ""
  echo "--- docker compose logs redis (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs redis --tail=50 2>/dev/null || true
  exit 1
fi

echo ""
echo "Smoke PASS: backend + postgres + redis all connected"

echo ""
echo "=== Smoke: Config Center ==="

# --- Config Center: Client Config Read ---
echo "--- GET /api/v1/config/client ---"
client_resp=$(curl -sS --max-time 5 "http://127.0.0.1:${BACKEND_HTTP_PORT}/api/v1/config/client") || true
echo "$client_resp" | python3 -m json.tool 2>/dev/null || echo "$client_resp"

client_key=$(echo "$client_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['config_key'])" 2>/dev/null || echo "")
client_ver=$(echo "$client_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['config_version'])" 2>/dev/null || echo "")
client_hash=$(echo "$client_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['config_hash'])" 2>/dev/null || echo "")

cc_failed=0
if [[ "$client_key" != "client.remote_config" ]]; then
  echo "FAIL: config_key=\"${client_key}\", expected \"client.remote_config\""
  cc_failed=1
fi
if [[ "$client_ver" -lt 1 ]] 2>/dev/null; then
  echo "FAIL: config_version=\"${client_ver}\", expected >= 1"
  cc_failed=1
fi
if [[ -z "$client_hash" ]]; then
  echo "FAIL: config_hash is empty"
  cc_failed=1
fi

# --- Config Center: NodeAgent Config Read ---
echo ""
echo "--- GET /internal/agent/config ---"
agent_resp=$(curl -sS --max-time 5 "http://127.0.0.1:${BACKEND_HTTP_PORT}/internal/agent/config") || true
echo "$agent_resp" | python3 -m json.tool 2>/dev/null || echo "$agent_resp"

agent_key=$(echo "$agent_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['config_key'])" 2>/dev/null || echo "")
if [[ "$agent_key" != "nodeagent.runtime_config" ]]; then
  echo "FAIL: agent config_key=\"${agent_key}\", expected \"nodeagent.runtime_config\""
  cc_failed=1
fi

# --- Config Center: Admin List ---
echo ""
echo "--- GET /admin/api/v1/configs ---"
admin_resp=$(curl -sS --max-time 5 "http://127.0.0.1:${BACKEND_HTTP_PORT}/admin/api/v1/configs") || true
echo "$admin_resp" | python3 -m json.tool 2>/dev/null || echo "$admin_resp"

admin_count=$(echo "$admin_resp" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['configs']))" 2>/dev/null || echo "0")
if [[ "$admin_count" -lt 2 ]]; then
  echo "FAIL: admin configs count=${admin_count}, expected >= 2"
  cc_failed=1
fi

# --- Config Center: Redis Cache Check ---
echo ""
echo "--- Redis cache: config:client.remote_config ---"
if docker compose -f "${COMPOSE_FILE}" exec -T redis redis-cli ping >/dev/null 2>&1; then
  redis_cache=$(docker compose -f "${COMPOSE_FILE}" exec -T redis redis-cli GET "config:client.remote_config" 2>/dev/null || true)
  if [[ -n "$redis_cache" ]]; then
    echo "Redis cache hit (payload length: ${#redis_cache})"
  else
    echo "FAIL: Redis cache config:client.remote_config is empty"
    cc_failed=1
  fi
else
  echo "FAIL: unable to query Redis container with redis-cli"
  cc_failed=1
fi

if [[ "$cc_failed" -eq 1 ]]; then
  echo ""
  echo "=== Config Center Smoke FAILED ==="
  exit 1
fi

echo ""
echo "Smoke PASS: config center endpoints OK (client + agent + admin + redis)"

# ── Seed dev admin & clean previous smoke user ───────────────────────────────
echo ""
echo "=== Smoke: Seed dev admin ==="
PG_EXEC="docker compose -f ${COMPOSE_FILE} exec -T postgres psql -U livemask"

# Clean smoke user from any previous run (FK cascade handles user_roles/sessions)
${PG_EXEC} -c "DELETE FROM users WHERE email='smoke@test.livemask'" 2>/dev/null || true

# Generate bcrypt hash for admin password (cost 12, matches backend)
ADMIN_HASH=$(${PG_EXEC} -tA -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -z "${ADMIN_HASH}" ]]; then
  echo "FAIL: unable to generate admin bcrypt hash"
  exit 1
fi
echo "bcrypt hash: ${ADMIN_HASH}"

# Insert admin user (idempotent)
${PG_EXEC} -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'" 2>/dev/null
echo "Inserted/updated admin user: admin@livemask.dev"

# Assign admin role
${PG_EXEC} -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
echo "Assigned 'admin' role to admin@livemask.dev"
echo "Smoke PASS: dev admin seeded OK"

# ── Run api-smoke ────────────────────────────────────────────────────────────
echo ""
echo "=== Smoke: Auth & RBAC (api-smoke.sh) ==="
api_smoke_rc=0
API_BASE_URL="http://127.0.0.1:${BACKEND_HTTP_PORT}" \
  API_WAIT_SECONDS=0 \
  bash "${SCRIPT_DIR}/api-smoke.sh" 2>&1 || api_smoke_rc=$?

# ── Cleanup smoke user (always) ──────────────────────────────────────────────
echo ""
echo "=== Smoke: Cleanup smoke user ==="
${PG_EXEC} -c "DELETE FROM users WHERE email='smoke@test.livemask'" 2>/dev/null || true
echo "Removed smoke@test.livemask"

if [[ "${api_smoke_rc:-0}" -ne 0 ]]; then
  echo ""
  echo "=== Auth Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit 1
fi

echo ""
echo "Smoke PASS: full stack (health + config center + auth/rbac)"
