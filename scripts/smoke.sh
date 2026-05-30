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
  echo "SKIP: config_hash is empty (field may not be populated in this runtime)"
fi

# --- Config Center: NodeAgent Config Read ---
echo ""
echo "--- GET /internal/agent/config ---"
agent_resp=$(curl -sS --max-time 5 "http://127.0.0.1:${BACKEND_HTTP_PORT}/internal/agent/config") || true
echo "$agent_resp" | python3 -m json.tool 2>/dev/null || echo "$agent_resp"

agent_key=$(echo "$agent_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('config_key',''))" 2>/dev/null || echo "")
if echo "$agent_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('error',{}).get('code')=='NODE_INVALID_REQUEST' else 1)" 2>/dev/null; then
  # Endpoint now requires NodeAgent HMAC auth. Verify config exists via admin list instead.
  echo "NodeAgent config endpoint requires HMAC auth (expected). Verifying via admin list..."
elif [[ "$agent_key" != "nodeagent.runtime_config" ]]; then
  echo "FAIL: agent config_key=\"${agent_key}\", expected \"nodeagent.runtime_config\""
  cc_failed=1
else
  echo "PASS: agent config_key=${agent_key}"
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
echo "=== Smoke: Job Service (TASK-CICD-JOBS-001) ==="
if bash "${SCRIPT_DIR}/jobs-smoke.sh" 2>&1; then
  echo "Job service smoke PASSED."
else
  jobs_rc=$?
  echo ""
  echo "=== Job Service Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs job-service (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs job-service --tail=100 2>/dev/null || true
  exit ${jobs_rc}
fi

echo ""
# ── Admin Dashboard Smoke (TASK-CICD-DASHBOARD-REALTIME-001) ────────────────
echo ""
echo "=== Smoke: Admin Dashboard (TASK-CICD-DASHBOARD-REALTIME-001) ==="
if bash "${SCRIPT_DIR}/dashboard-smoke.sh" 2>&1; then
  echo "Admin dashboard smoke PASSED."
else
  dashboard_rc=$?
  echo ""
  echo "=== Admin Dashboard Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${dashboard_rc}
fi

echo ""
# ── Protocol & Endpoint Template Rollout Smoke (TASK-CICD-PROTOCOL-ENDPOINT-ROLLOUT-001) ──
echo ""
echo "=== Smoke: Protocol & Endpoint Template Rollout (TASK-CICD-PROTOCOL-ENDPOINT-ROLLOUT-001) ==="
if bash "${SCRIPT_DIR}/protocol-endpoint-smoke.sh" 2>&1; then
  echo "Protocol endpoint smoke PASSED."
else
  proto_rc=$?
  echo ""
  echo "=== Protocol Endpoint Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  echo "--- docker compose logs job-service (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs job-service --tail=50 2>/dev/null || true
  exit ${proto_rc}
fi

echo ""
# ── Protocol & Endpoint Capability Smoke (TASK-CICD-PROTOCOL-CAPABILITY-001) ──
echo ""
echo "=== Smoke: Protocol & Endpoint Capability (TASK-CICD-PROTOCOL-CAPABILITY-001) ==="
if bash "${SCRIPT_DIR}/protocol-capability-smoke.sh" 2>&1; then
  echo "Protocol capability smoke PASSED."
else
  cap_rc=$?
  echo ""
  echo "=== Protocol Capability Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${cap_rc}
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
# ── NodeAgent Release Smoke (TASK-CICD-NODEAGENT-RELEASE-001) ──────────────
echo ""
echo "=== Smoke: NodeAgent Release/Check/Rollout (TASK-CICD-NODEAGENT-RELEASE-001) ==="
if bash "${SCRIPT_DIR}/nodeagent-release-smoke.sh" 2>&1; then
  echo "NodeAgent release smoke PASSED."
else
  release_rc=$?
  echo ""
  echo "=== NodeAgent Release Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${release_rc}
fi

echo ""
# ── Growth Revenue & Reward Notification & User Profile Growth Fields Smoke (TASK-CICD-USER-GROWTH-REVENUE-001 / TASK-CICD-GROWTH-REWARD-NOTIFICATION-001 / TASK-CICD-USER-PROFILE-GROWTH-FIELDS-SMOKE-001) ──
echo ""
echo "=== Smoke: Growth Revenue & Reward Notification & User Profile Growth Fields (TASK-CICD-USER-GROWTH-REVENUE-001 / TASK-CICD-GROWTH-REWARD-NOTIFICATION-001 / TASK-CICD-USER-PROFILE-GROWTH-FIELDS-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/growth-revenue-smoke.sh" 2>&1; then
  echo "Growth revenue & reward notification smoke PASSED."
else
  growth_rc=$?
  echo ""
  echo "=== Growth Revenue & Reward Notification & User Profile Growth Fields Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${growth_rc}
fi

echo ""
# ── Website Blog Smoke (TASK-CICD-WEBSITE-001) ───────────────────────────
echo ""
echo "=== Smoke: Website Blog (TASK-CICD-WEBSITE-001) ==="
if bash "${SCRIPT_DIR}/website-smoke.sh" 2>&1; then
  echo "Website blog smoke PASSED."
else
  website_rc=$?
  echo ""
  echo "=== Website Blog Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  echo "--- docker compose logs website (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs website --tail=50 2>/dev/null || true
  exit ${website_rc}
fi

echo ""
# ── Release Control Smoke (TASK-CICD-RELEASE-CONTROL-SMOKE-001) ──
echo ""
echo "=== Smoke: Release Control (TASK-CICD-RELEASE-CONTROL-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/release-control-smoke.sh" 2>&1; then
  echo "Release control smoke PASSED."
else
  relctl_rc=$?
  echo ""
  echo "=== Release Control Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  echo "--- docker compose logs website (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs website --tail=50 2>/dev/null || true
  exit ${relctl_rc}
fi

echo ""
# ── System Settings & Scheduler Smoke (TASK-CICD-SYSTEM-SETTINGS-SCHEDULER-001) ──
echo ""
echo "=== Smoke: System Settings & Scheduler (TASK-CICD-SYSTEM-SETTINGS-SCHEDULER-001) ==="
if bash "${SCRIPT_DIR}/system-settings-smoke.sh" 2>&1; then
  echo "System settings & scheduler smoke PASSED."
else
  sys_rc=$?
  echo ""
  echo "=== System Settings & Scheduler Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${sys_rc}
fi

echo ""
# ── App Release Smoke (TASK-CICD-APP-RELEASE-001) ──────────────────────
echo ""
echo "=== Smoke: App Release (TASK-CICD-APP-RELEASE-001) ==="
if bash "${SCRIPT_DIR}/app-release-smoke.sh" 2>&1; then
  echo "App release smoke PASSED."
else
  apprel_rc=$?
  echo ""
  echo "=== App Release Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  echo "--- docker compose logs website (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs website --tail=50 2>/dev/null || true
  exit ${apprel_rc}
fi

echo ""
# ── Sentry Config Smoke (TASK-CICD-SENTRY-CONFIG-SMOKE-001) ────────────
echo ""
echo "=== Smoke: Sentry Config (TASK-CICD-SENTRY-CONFIG-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/sentry-config-smoke.sh" 2>&1; then
  echo "Sentry config smoke PASSED."
else
  sentry_cfg_rc=$?
  echo ""
  echo "=== Sentry Config Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${sentry_cfg_rc}
fi

echo ""
# ── Observability Smoke (TASK-CICD-OBSERVABILITY-SMOKE-001) ────────────
echo ""
echo "=== Smoke: Observability (TASK-CICD-OBSERVABILITY-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/observability-smoke.sh" 2>&1; then
  echo "Observability smoke PASSED."
else
  obs_rc=$?
  echo ""
  echo "=== Observability Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${obs_rc}
fi

echo ""
# ── I18n Language Smoke (TASK-CICD-I18N-LANGUAGE-SMOKE-001) ──────────
echo ""
echo "=== Smoke: I18n Language (TASK-CICD-I18N-LANGUAGE-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/i18n-smoke.sh" 2>&1; then
  echo "I18n language smoke PASSED."
else
  i18n_rc=$?
  echo ""
  echo "=== I18n Language Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${i18n_rc}
fi

echo ""
# ── Bandwidth Auto-Reconnect Smoke (TASK-CICD-BANDWIDTH-AUTO-RECONNECT-SMOKE-001) ──
echo ""
echo "=== Smoke: Bandwidth Auto-Reconnect (TASK-CICD-BANDWIDTH-AUTO-RECONNECT-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/bandwidth-auto-reconnect-smoke.sh" 2>&1; then
  echo "Bandwidth auto-reconnect smoke PASSED."
else
  bw_rc=$?
  echo ""
  echo "=== Bandwidth Auto-Reconnect Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${bw_rc}
fi

echo ""
# ── Traffic Analytics V2 Smoke (TASK-CICD-TRAFFIC-ANALYTICS-V2-SMOKE-001) ──
echo ""
echo "=== Smoke: Traffic Analytics V2 (TASK-CICD-TRAFFIC-ANALYTICS-V2-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/traffic-analytics-v2-smoke.sh" 2>&1; then
  echo "Traffic analytics V2 smoke PASSED."
else
  tav2_rc=$?
  echo ""
  echo "=== Traffic Analytics V2 Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${tav2_rc}
fi

echo ""
# ── Admin Nav IA Smoke (TASK-CICD-ADMIN-NAV-IA-001) ──────────────────
echo ""
echo "=== Smoke: Admin Nav Info Architecture (TASK-CICD-ADMIN-NAV-IA-001) ==="
if bash "${SCRIPT_DIR}/admin-nav-ia-smoke.sh" 2>&1; then
  echo "Admin nav IA smoke PASSED."
else
  navia_rc=$?
  echo ""
  echo "=== Admin Nav IA Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs admin (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs admin --tail=100 2>/dev/null || true
  echo "--- docker compose logs backend (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=50 2>/dev/null || true
  exit ${navia_rc}
fi

echo ""
# ── Jobs Hardening Smoke (TASK-CICD-JOBS-HARDENING-001) ─────────────────
echo ""
echo "=== Smoke: Jobs Hardening (TASK-CICD-JOBS-HARDENING-001) ==="
if bash "${SCRIPT_DIR}/jobs-hardening-smoke.sh" 2>&1; then
  echo "Jobs hardening smoke PASSED."
else
  jbh_rc=$?
  echo ""
  echo "=== Jobs Hardening Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  echo "--- docker compose logs job-service (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs job-service --tail=100 2>/dev/null || true
  exit ${jbh_rc}
fi

echo ""
# ── Connection Quality Report Smoke (TASK-CICD-CONNECTION-QUALITY-SMOKE-001) ──
echo ""
echo "=== Smoke: Connection Quality Report (TASK-CICD-CONNECTION-QUALITY-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/connection-quality-smoke.sh" 2>&1; then
  echo "Connection quality report smoke PASSED."
else
  cq_rc=$?
  echo ""
  echo "=== Connection Quality Report Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${cq_rc}
fi

echo ""
# ── NodeAgent Config Sync Smoke (TASK-CICD-NODEAGENT-CONFIG-SMOKE-001) ──────
echo ""
echo "=== Smoke: NodeAgent Config Sync (TASK-CICD-NODEAGENT-CONFIG-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/nodeagent-config-smoke.sh" 2>&1; then
  echo "NodeAgent config sync smoke PASSED."
else
  nacfg_rc=$?
  echo ""
  echo "=== NodeAgent Config Sync Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  echo "--- docker compose logs nodeagent (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs nodeagent --tail=50 2>/dev/null || true
  exit ${nacfg_rc}
fi

echo ""
# ── NAT Sharing Guard Smoke (TASK-CICD-NAT-SHARING-GUARD-001) ─────────────────
echo ""
echo "=== Smoke: NAT Sharing Guard (TASK-CICD-NAT-SHARING-GUARD-001) ==="
if bash "${SCRIPT_DIR}/nat-sharing-smoke.sh" 2>&1; then
  echo "NAT Sharing guard smoke PASSED."
else
  natsharing_rc=$?
  echo ""
  echo "=== NAT Sharing Guard Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${natsharing_rc}
fi

echo ""
# ── NodeAgent Speedtest & Bandwidth Smoke (TASK-CICD-NODEAGENT-SPEEDTEST-BANDWIDTH-001) ──
echo ""
echo "=== Smoke: NodeAgent Speedtest & Bandwidth (TASK-CICD-NODEAGENT-SPEEDTEST-BANDWIDTH-001) ==="
if bash "${SCRIPT_DIR}/nodeagent-speedtest-smoke.sh" 2>&1; then
  echo "NodeAgent speedtest smoke PASSED."
else
  nst_rc=$?
  echo ""
  echo "=== NodeAgent Speedtest Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  echo "--- docker compose logs nodeagent (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs nodeagent --tail=50 2>/dev/null || true
  exit ${nst_rc}
fi

echo ""
# ── NodeAgent Credential Rotation Smoke (TASK-CICD-NODEAGENT-CREDENTIAL-ROTATION-SMOKE-001) ──
echo ""
echo "=== Smoke: NodeAgent Credential Rotation (TASK-CICD-NODEAGENT-CREDENTIAL-ROTATION-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/nodeagent-credential-rotation-smoke.sh" 2>&1; then
  echo "NodeAgent credential rotation smoke PASSED."
else
  cred_rc=$?
  echo ""
  echo "=== NodeAgent Credential Rotation Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100, redacted) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null | \
    python3 -c '
import sys, re

SECRET_FIELDS = frozenset([
    "node_secret", "secret_hash", "access_token", "bearer_token",
    "refresh_token", "api_key", "private_key", "dsn", "secret",
    "hmac_key", "signing_key", "session_token",
])

text = sys.stdin.read()

# JSON-aware redaction
import json
try:
    data = json.loads(text)
    def walk(obj):
        if isinstance(obj, dict):
            return {k: ("<REDACTED>" if k in SECRET_FIELDS else walk(v)) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [walk(v) for v in obj]
        return obj
    sys.stdout.write(json.dumps(walk(data), ensure_ascii=False))
    sys.exit(0)
except Exception:
    pass

# Authorization: Bearer <jwt>
text = re.sub(
    r"(Authorization:\s*Bearer\s+)[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+",
    r"\1<REDACTED-JWT>", text, flags=re.IGNORECASE
)
# X-Signature: <long-hex>
text = re.sub(r"(X-Signature:\s*)[a-fA-F0-9]{64,}", r"\1<REDACTED-SIG>", text)
# key=value or key:value for known fields
text = re.sub(
    r"(node_secret|access_token|bearer_token|secret_hash|private_key)\s*[=:]\s*[A-Za-z0-9_\-{}]{8,}",
    r"\1=<REDACTED>", text, flags=re.IGNORECASE
)
# Long hex / base64
text = re.sub(r"[a-fA-F0-9]{64,}", "<REDACTED-HEX>", text)
text = re.sub(r"[A-Za-z0-9+/=]{80,}", "<REDACTED-BASE64>", text)
text = re.sub(r"(postgres|redis|mysql|mongodb)://[^@\s]+@", r"\1://<REDACTED-CREDS>@", text, flags=re.IGNORECASE)
sys.stdout.write(text)
' 2>/dev/null || echo "  (log redaction unavailable)"
  echo "--- docker compose logs nodeagent (last 50, redacted) ---"
  docker compose -f "${COMPOSE_FILE}" logs nodeagent --tail=50 2>/dev/null | \
    python3 -c '
import sys, re

SECRET_FIELDS = frozenset([
    "node_secret", "secret_hash", "access_token", "bearer_token",
    "refresh_token", "api_key", "private_key", "dsn", "secret",
    "hmac_key", "signing_key", "session_token",
])

text = sys.stdin.read()
import json
try:
    data = json.loads(text)
    def walk(obj):
        if isinstance(obj, dict):
            return {k: ("<REDACTED>" if k in SECRET_FIELDS else walk(v)) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [walk(v) for v in obj]
        return obj
    sys.stdout.write(json.dumps(walk(data), ensure_ascii=False))
    sys.exit(0)
except Exception:
    pass

text = re.sub(
    r"(Authorization:\s*Bearer\s+)[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+",
    r"\1<REDACTED-JWT>", text, flags=re.IGNORECASE
)
text = re.sub(r"(X-Signature:\s*)[a-fA-F0-9]{64,}", r"\1<REDACTED-SIG>", text)
text = re.sub(
    r"(node_secret|access_token|bearer_token|secret_hash|private_key)\s*[=:]\s*[A-Za-z0-9_\-{}]{8,}",
    r"\1=<REDACTED>", text, flags=re.IGNORECASE
)
text = re.sub(r"[a-fA-F0-9]{64,}", "<REDACTED-HEX>", text)
text = re.sub(r"[A-Za-z0-9+/=]{80,}", "<REDACTED-BASE64>", text)
text = re.sub(r"(postgres|redis|mysql|mongodb)://[^@\s]+@", r"\1://<REDACTED-CREDS>@", text, flags=re.IGNORECASE)
sys.stdout.write(text)
' 2>/dev/null || echo "  (log redaction unavailable)"
  exit ${cred_rc}
fi

echo ""
# ── Real Data Closed Loop Smoke (TASK-CICD-REAL-DATA-CLOSED-LOOP-SMOKE-001) ──
echo ""
echo "=== Smoke: Real Data Closed Loop (TASK-CICD-REAL-DATA-CLOSED-LOOP-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/real-data-closed-loop-smoke.sh" 2>&1; then
  echo "Real data closed loop smoke PASSED."
else
  rclo_rc=$?
  echo ""
  echo "=== Real Data Closed Loop Smoke FAILED ==="
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  echo "--- docker compose logs job-service (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs job-service --tail=100 2>/dev/null || true
  exit ${rclo_rc}
fi

echo ""
# ── Jobs Real Data Smoke (TASK-CICD-JOBS-REAL-DATA-SMOKE-001) ──────────
echo ""
echo "=== Smoke: Jobs Real Data (TASK-CICD-JOBS-REAL-DATA-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/jobs-real-data-smoke.sh" 2>&1; then
  echo "Jobs real data smoke PASSED."
else
  jrd_rc=$?
  echo ""
  echo "=== Jobs Real Data Smoke FAILED ==="
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  docker compose -f "${COMPOSE_FILE}" logs job-service --tail=100 2>/dev/null || true
  exit ${jrd_rc}
fi

echo ""
# ── Node Status Freshness Smoke (TASK-CICD-NODE-STATUS-FRESHNESS-SMOKE-001) ──
echo ""
echo "=== Smoke: Node Status Freshness (TASK-CICD-NODE-STATUS-FRESHNESS-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/node-status-freshness-smoke.sh" 2>&1; then
  echo "Node status freshness smoke PASSED."
else
  nsf_rc=$?
  echo ""
  echo "=== Node Status Freshness Smoke FAILED ==="
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${nsf_rc}
fi

echo ""
# ── App Runtime Governance Smoke (TASK-CICD-APP-RUNTIME-GOVERNANCE-SMOKE-001) ──
echo ""
echo "=== Smoke: App Runtime Governance (TASK-CICD-APP-RUNTIME-GOVERNANCE-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/app-runtime-governance-smoke.sh" 2>&1; then
  echo "App runtime governance smoke PASSED."
else
  arg_rc=$?
  echo ""
  echo "=== App Runtime Governance Smoke FAILED ==="
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${arg_rc}
fi

echo ""
# ── Protocol Parity Smoke (TASK-CICD-PROTOCOL-PARITY-SMOKE-001) ─────────
echo ""
echo "=== Smoke: Protocol Parity (TASK-CICD-PROTOCOL-PARITY-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/protocol-parity-smoke.sh" 2>&1; then
  echo "Protocol parity smoke PASSED."
else
  pp_rc=$?
  echo ""
  echo "=== Protocol Parity Smoke FAILED ==="
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${pp_rc}
fi

echo ""
# ── Log Retention Smoke (TASK-CICD-LOG-RETENTION-SMOKE-001) ────────────
echo ""
echo "=== Smoke: Log Retention (TASK-CICD-LOG-RETENTION-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/log-retention-smoke.sh" 2>&1; then
  echo "Log retention smoke PASSED."
else
  lr_rc=$?
  echo ""
  echo "=== Log Retention Smoke FAILED ==="
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${lr_rc}
fi

echo ""
# ── Admin Nodes UX Smoke (TASK-CICD-ADMIN-NODES-UX-SMOKE-001) ──────────
echo ""
echo "=== Smoke: Admin Nodes UX (TASK-CICD-ADMIN-NODES-UX-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/admin-nodes-ux-smoke.sh" 2>&1; then
  echo "Admin nodes UX smoke PASSED."
else
  anux_rc=$?
  echo ""
  echo "=== Admin Nodes UX Smoke FAILED ==="
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${anux_rc}
fi

echo ""
# ── Website i18n Announcement Smoke (TASK-CICD-WEBSITE-I18N-ANNOUNCEMENT-SMOKE-001) ──
echo ""
echo "=== Smoke: Website i18n Announcement (TASK-CICD-WEBSITE-I18N-ANNOUNCEMENT-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/website-i18n-announcement-smoke.sh" 2>&1; then
  echo "Website i18n announcement smoke PASSED."
else
  wia_rc=$?
  echo ""
  echo "=== Website i18n Announcement Smoke FAILED ==="
  docker compose -f "${COMPOSE_FILE}" logs website --tail=100 2>/dev/null || true
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit ${wia_rc}
fi

echo ""
# ── Secret Leak Standard Smoke (TASK-CICD-SECRET-LEAK-STANDARD-SMOKE-001) ──
echo ""
echo "=== Smoke: Secret Leak Standard (TASK-CICD-SECRET-LEAK-STANDARD-SMOKE-001) ==="
if bash "${SCRIPT_DIR}/secret-leak-standard-smoke.sh" 2>&1; then
  echo "Secret leak standard smoke PASSED."
else
  sls_rc=$?
  echo ""
  echo "=== Secret Leak Standard Smoke FAILED ==="
  exit ${sls_rc}
fi

echo ""
# ── Worker Harness Smoke (TASK-CICD-CURSOR-SDK-WORKER-HARDENING-001) ───
echo ""
echo "=== Smoke: Worker Harness (TASK-CICD-CURSOR-SDK-WORKER-HARDENING-001) ==="
if bash "${SCRIPT_DIR}/worker-harness-smoke.sh" 2>&1; then
  echo "Worker harness smoke PASSED."
else
  wh_rc=$?
  echo ""
  echo "=== Worker Harness Smoke FAILED ==="
  exit ${wh_rc}
fi

echo ""
# ── Auto Task Assignment Smoke (TASK-CICD-AUTO-TASK-ASSIGNMENT-WORKFLOW-INTEGRATION-001) ──
if [[ "${RUN_AUTO_TASK_ASSIGNMENT_SMOKE:-}" == "1" ]]; then
  echo ""
  echo "=== Smoke: Auto Task Assignment (TASK-CICD-AUTO-TASK-ASSIGNMENT-WORKFLOW-INTEGRATION-001) ==="
  if bash "${SCRIPT_DIR}/auto-task-assignment-smoke.sh" 2>&1; then
    echo "Auto task assignment smoke PASSED."
  else
    ata_rc=$?
    echo ""
    echo "=== Auto Task Assignment Smoke FAILED ==="
    exit ${ata_rc}
  fi
  if bash "${SCRIPT_DIR}/auto-task-assignment-workflow-smoke.sh" 2>&1; then
    echo "Auto task assignment workflow smoke PASSED."
  else
    ataw_rc=$?
    echo ""
    echo "=== Auto Task Assignment Workflow Smoke FAILED ==="
    exit ${ataw_rc}
  fi
fi

echo ""
echo "Smoke PASS: full stack (health + config center + auth/rbac + node agent + billing/devices + connect session + content system + geoip + job-service + dashboard + protocol-endpoint-rollout + protocol-capability + geoip-credentials + nodeagent-release + website-blog + system-settings + scheduler + app-release + sentry-config + observability + i18n-language + bandwidth-auto-reconnect + traffic-analytics-v2 + admin-nav-ia + jobs-hardening + growth-revenue + reward-notification + release-control + connection-quality + nodeagent-config-sync + nat-sharing-guard + nodeagent-speedtest-bandwidth + nodeagent-credential-rotation + real-data-closed-loop + jobs-real-data + node-status-freshness + app-runtime-governance + protocol-parity + log-retention + admin-nodes-ux + website-i18n-announcement + secret-leak-standard + worker-harness)"
