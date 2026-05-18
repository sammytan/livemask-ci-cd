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

# ── Node Agent Smoke (TASK-NODE-001) ─────────────────────────────────────────
echo ""
echo "=== Smoke: Node Agent (TASK-NODE-001) ==="

# --- Login as admin (already seeded above) ---
ADMIN_TOKEN=$(curl -sS --max-time 5 -X POST "http://127.0.0.1:${BACKEND_HTTP_PORT}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"smoke-node-admin","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
if [[ -z "${ADMIN_TOKEN}" ]]; then
  echo "FAIL: unable to login as admin for node smoke"
  exit 1
fi
echo "Admin login OK (token length: ${#ADMIN_TOKEN})"

# --- Register a test user and login ---
USER_REG=$(curl -sS --max-time 5 -X POST "http://127.0.0.1:${BACKEND_HTTP_PORT}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"smoke-node-user","email":"node-test@test.livemask","password":"NodeTestPass123!","display_name":"Node Smoke User","client_type":"app"}') 2>/dev/null || true
USER_REG_CODE=$(echo "$USER_REG" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('access_token',''))" 2>/dev/null || echo "")
# If 409 (already exists), login instead
if [[ -z "${USER_REG_CODE}" ]]; then
  USER_TOKEN=$(curl -sS --max-time 5 -X POST "http://127.0.0.1:${BACKEND_HTTP_PORT}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"request_id":"smoke-node-user-login","email":"node-test@test.livemask","password":"NodeTestPass123!","client_type":"app"}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
else
  USER_TOKEN="${USER_REG_CODE}"
fi
if [[ -z "${USER_TOKEN}" ]]; then
  echo "FAIL: unable to get user token for node smoke"
  exit 1
fi
echo "User login OK (token length: ${#USER_TOKEN})"

# --- Step 1: Register a node ---
NODE_REG=$(curl -sS --max-time 5 -X POST "http://127.0.0.1:${BACKEND_HTTP_PORT}/internal/agent/register" \
  -H "Content-Type: application/json" \
  -d '{"node_name":"smoke-test-node","agent_version":"smoke-1.0.0"}') 2>/dev/null || true
NODE_ID=$(echo "$NODE_REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['node_id'])" 2>/dev/null || echo "")
NODE_SECRET=$(echo "$NODE_REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['node_secret'])" 2>/dev/null || echo "")
NODE_STATUS=$(echo "$NODE_REG" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "")
if [[ -z "${NODE_ID}" || -z "${NODE_SECRET}" ]]; then
  echo "FAIL: node register did not return node_id/node_secret"
  echo "Response: ${NODE_REG}"
  exit 1
fi
echo "Node registered: id=${NODE_ID} status=${NODE_STATUS}"

# --- Step 2: Compute HMAC and send heartbeat ---
HB_TIMESTAMP=$(date +%s)
# Compute SHA-256 hash of node_secret (matches backend's HashSecret)
NODE_SECRET_HASH=$(echo -n "${NODE_SECRET}" | sha256sum | cut -d' ' -f1)
# Compute HMAC-SHA256(node_id:timestamp, key=secret_hash)
HB_SIGNATURE=$(python3 -c "
import hmac, hashlib
secret_hash = '${NODE_SECRET_HASH}'
msg = '${NODE_ID}:${HB_TIMESTAMP}'
sig = hmac.new(secret_hash.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
")

HB_RESP=$(curl -sS --max-time 5 -X POST "http://127.0.0.1:${BACKEND_HTTP_PORT}/internal/agent/heartbeat" \
  -H "Content-Type: application/json" \
  -H "X-Node-ID: ${NODE_ID}" \
  -H "X-Signature: ${HB_SIGNATURE}" \
  -H "X-Timestamp: ${HB_TIMESTAMP}" \
  -d '{"agent_version":"smoke-1.0.0","config_version":1,"singbox_status":"running","load_score":42,"cpu_usage":0.35,"memory_usage":0.55,"network_tx_bytes":1024,"network_rx_bytes":2048,"active_connections":5,"degraded":false}') 2>/dev/null || true
HB_OK=$(echo "$HB_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',''))" 2>/dev/null || echo "")
if [[ "${HB_OK}" != "True" ]]; then
  echo "FAIL: heartbeat failed"
  echo "Response: ${HB_RESP}"
  exit 1
fi
echo "Heartbeat OK (response: ${HB_RESP})"

# --- Step 3: Admin verify node appears in node list ---
ADMIN_NODES=$(curl -sS --max-time 5 -X GET "http://127.0.0.1:${BACKEND_HTTP_PORT}/admin/api/v1/nodes" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") 2>/dev/null || true
ADMIN_NODE_COUNT=$(echo "${ADMIN_NODES}" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['nodes']))" 2>/dev/null || echo "0")
ADMIN_FOUND_ID=$(echo "${ADMIN_NODES}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for n in data['nodes']:
    if n['id'] == '${NODE_ID}':
        print(n['id'])
" 2>/dev/null || echo "")
if [[ "${ADMIN_FOUND_ID}" != "${NODE_ID}" ]]; then
  echo "FAIL: node ${NODE_ID} not found in admin node list"
  echo "Admin nodes: ${ADMIN_NODES}"
  exit 1
fi
echo "Admin node list OK (total=${ADMIN_NODE_COUNT}, found node)"

# --- Step 4: Approve node via SQL (no admin approve endpoint yet) ---
${PG_EXEC} -c "UPDATE nodes SET status='active', approved_at=NOW(), approved_by='smoke' WHERE id='${NODE_ID}'" 2>/dev/null
echo "Node approved (status → active)"

# --- Step 5: User verify node appears in public node list ---
PUBLIC_NODES=$(curl -sS --max-time 5 -X GET "http://127.0.0.1:${BACKEND_HTTP_PORT}/api/v1/nodes" \
  -H "Authorization: Bearer ${USER_TOKEN}") 2>/dev/null || true
PUBLIC_FOUND_ID=$(echo "${PUBLIC_NODES}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for n in data['nodes']:
    if n['id'] == '${NODE_ID}':
        print(n['id'])
" 2>/dev/null || echo "")
if [[ "${PUBLIC_FOUND_ID}" != "${NODE_ID}" ]]; then
  echo "FAIL: node ${NODE_ID} not found in public node list"
  echo "Public nodes: ${PUBLIC_NODES}"
  exit 1
fi
echo "Public node list OK (found node in active nodes)"

# --- Step 6: Verify public node does NOT leak security fields ---
LEAK_CHECK=$(echo "${PUBLIC_NODES}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for n in data['nodes']:
    if 'ip_address' in n or 'node_secret' in n or 'agent_version' in n:
        print('LEAK')
        break
else:
    print('OK')
" 2>/dev/null || echo "OK")
if [[ "${LEAK_CHECK}" == "LEAK" ]]; then
  echo "FAIL: public node list leaks security fields"
  echo "Public nodes: ${PUBLIC_NODES}"
  exit 1
fi
echo "Public node list safe (no security fields leaked)"

echo "Smoke PASS: node agent flow (register + heartbeat + admin verify + public verify)"

# ── Cleanup node + test users ────────────────────────────────────────────────
echo ""
echo "=== Smoke: Cleanup node smoke data ==="
${PG_EXEC} -c "DELETE FROM nodes WHERE node_name='smoke-test-node'" 2>/dev/null || true
${PG_EXEC} -c "DELETE FROM users WHERE email='node-test@test.livemask'" 2>/dev/null || true
echo "Removed node smoke data"

echo ""
# ── Connect Session Smoke (TASK-CICD-CONNECT-001) ──────────────────────────
echo ""
echo "=== Smoke: Connect Session (TASK-CICD-CONNECT-001) ==="
if bash "${SCRIPT_DIR}/connect-smoke.sh" 2>&1; then
  echo "Connect session smoke PASSED."
else
  connect_rc=$?
  echo ""
  echo "=== Connect Session Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${connect_rc}
fi

echo ""
# ── Content System Smoke (TASK-CICD-CONTENT-SEO-001) ─────────────────────
echo ""
echo "=== Smoke: Content System (TASK-CICD-CONTENT-SEO-001) ==="
if bash "${SCRIPT_DIR}/content-smoke.sh" 2>&1; then
  echo "Content system smoke PASSED."
else
  content_rc=$?
  echo ""
  echo "=== Content System Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${content_rc}
fi

echo ""
# ── GeoIP Smoke (TASK-CICD-GEOIP-001) ──────────────────────────────────
echo ""
echo "=== Smoke: GeoIP System (TASK-CICD-GEOIP-001) ==="
if bash "${SCRIPT_DIR}/geoip-smoke.sh" 2>&1; then
  echo "GeoIP system smoke PASSED."
else
  geoip_rc=$?
  echo ""
  echo "=== GeoIP System Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${geoip_rc}
fi

echo ""
echo "=== Smoke: GeoIP Credentials (TASK-CICD-GEOIP-CREDENTIALS-001) ==="
if bash "${SCRIPT_DIR}/geoip-credentials-smoke.sh" 2>&1; then
  echo "GeoIP credentials smoke PASSED."
else
  cred_rc=$?
  echo ""
  echo "=== GeoIP Credentials Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${cred_rc}
fi

echo ""
echo "Smoke PASS: full stack (health + config center + auth/rbac + node agent + billing/devices + connect session + content system + geoip + geoip-credentials)"
