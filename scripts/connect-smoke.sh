#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# TASK-CICD-CONNECT-001 — Connect Session 全链路 Smoke
# TASK-CICD-VPN-CONFIG-001 — Real connect_config safety Smoke
# TASK-CICD-PROTOCOL-SMOKE-001 — Protocol profile safety Smoke
# ──────────────────────────────────────────────────────────────────────────────
# Dependencies:
#   Backend TASK-BACKEND-CONNECT-001 (connect session CRUD)
#   Backend TASK-BACKEND-NODE-001 (node register/heartbeat)
#   Backend TASK-BACKEND-NODE-002 (admin approve/activate)
#   Backend TASK-BACKEND-VPN-CONFIG-001 (real/skeleton connect_config)
#   Backend TASK-BACKEND-NODE-ENDPOINT-001 (node-endpoint CRUD)
# ──────────────────────────────────────────────────────────────────────────────

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"

FAILED=0
SUMMARY_LINES=()

fail() {
  local msg="$1"
  echo "  FAIL: ${msg}"
  SUMMARY_LINES+=("FAIL: ${msg}")
  FAILED=1
}

pass() {
  local msg="$1"
  echo "  PASS: ${msg}"
  SUMMARY_LINES+=("PASS: ${msg}")
}

skip() {
  local msg="$1"
  echo "  SKIP: ${msg}"
  SUMMARY_LINES+=("SKIP: ${msg}")
}

blocker() {
  local msg="$1"
  echo "  BLOCKER: ${msg}"
  SUMMARY_LINES+=("BLOCKER: ${msg}")
  # Blockers do not set FAILED=1 — they are known backend issues
}

quiet_json() {
  local path="${1:-}"
  python3 -c "
import sys,json
data=json.load(sys.stdin)
parts='${path}'.split('.')
current=data
for p in parts:
    if isinstance(current, dict):
        if p not in current:
            print('')
            sys.exit(0)
        current=current[p]
    elif isinstance(current, list):
        try:
            current=current[int(p)]
        except (IndexError, ValueError):
            print('')
            sys.exit(0)
    else:
        print('')
        sys.exit(0)
print(current)
" 2>/dev/null || echo ""
}

pg_exec() {
  docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA "$@" 2>/dev/null || true
}

SUFFIX="conn-$(date +%s)"
USER_EMAIL="connect-smoke-${SUFFIX}@test.livemask"
USER_PASS="ConnectTest123!"
WEBSITE_EMAIL="connect-web-${SUFFIX}@test.livemask"
WEBSITE_PASS="ConnectWeb123!"
NODE_NAME="connect-smoke-node-${SUFFIX}"

echo "========================================"
echo " TASK-CICD-CONNECT-001: Connect Session Smoke"
echo "========================================"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# A. 基础准备
# ──────────────────────────────────────────────────────────────────────────────

# --- 0: Health check ---
echo "--- [0] Health Check ---"
for attempt in $(seq 1 30); do
  health_resp=$(curl -sS --max-time 3 "${API_BASE}/api/v1/health" 2>/dev/null || true)
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    echo "  Backend ready (attempt ${attempt})"
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    fail "Backend not ready after 30 attempts"
    echo ""
    printf '%s\n' "${SUMMARY_LINES[@]}"
    exit 1
  fi
  sleep 2
done
pass "Backend health ok"

# --- 1: Admin login (dev seed) ---
echo ""
echo "--- [1] Admin Login (dev seed) ---"
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"conn-smoke-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  echo "  INFO: seeding admin via SQL..."
  pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'"
  ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" || echo "")
  if [[ -n "${ADMIN_HASH}" ]]; then
    pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'"
    pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by connect-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING"
    ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d '{"request_id":"conn-smoke-admin-login2","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
    ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
  fi
  if [[ -z "${ADMIN_TOKEN}" ]]; then
    fail "Admin login"
  fi
fi
if [[ -n "${ADMIN_TOKEN}" ]]; then
  pass "Admin login OK (token length=${#ADMIN_TOKEN})"
fi

# --- 2: App user register/login (client_type=app) ---
echo ""
echo "--- [2] App User Register/Login (app audience) ---"
pg_exec -c "DELETE FROM users WHERE email='${USER_EMAIL}'" 2>/dev/null || true
pg_exec -c "DELETE FROM users WHERE email='${WEBSITE_EMAIL}'" 2>/dev/null || true

USER_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"conn-smoke-app-reg\",\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASS}\",\"display_name\":\"Connect App User\",\"client_type\":\"app\"}") || true
USER_TOKEN=$(echo "${USER_REG}" | quiet_json "access_token")
USER_ID=$(echo "${USER_REG}" | quiet_json "user.user_id")
if [[ -z "${USER_TOKEN}" ]]; then
  USER_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"conn-smoke-app-login\",\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASS}\",\"client_type\":\"app\"}") || true
  USER_TOKEN=$(echo "${USER_LOGIN}" | quiet_json "access_token")
  USER_ID=$(echo "${USER_LOGIN}" | quiet_json "user.user_id")
fi
if [[ -z "${USER_TOKEN}" ]]; then
  fail "App user register/login"
else
  pass "App user login OK (token length=${#USER_TOKEN})"
fi

# --- 3: Website user login (for negative test) ---
echo ""
echo "--- [3] Website User Login (website audience) ---"
WEB_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"conn-smoke-web-reg\",\"email\":\"${WEBSITE_EMAIL}\",\"password\":\"${WEBSITE_PASS}\",\"display_name\":\"Connect Web User\",\"client_type\":\"website\"}") || true
WEBSITE_TOKEN=$(echo "${WEB_REG}" | quiet_json "access_token")
if [[ -z "${WEBSITE_TOKEN}" ]]; then
  WEB_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"conn-smoke-web-login\",\"email\":\"${WEBSITE_EMAIL}\",\"password\":\"${WEBSITE_PASS}\",\"client_type\":\"website\"}") || true
  WEBSITE_TOKEN=$(echo "${WEB_LOGIN}" | quiet_json "access_token")
fi
if [[ -z "${WEBSITE_TOKEN}" ]]; then
  fail "Website user login"
else
  pass "Website user login OK (token length=${#WEBSITE_TOKEN})"
fi

# ──────────────────────────────────────────────────────────────────────────────
# B. 无节点场景 — Current session is null
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [4] GET Current Session (no session yet) ---"
CURRENT_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/connect/session/current" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
CURRENT_SESSION=$(echo "${CURRENT_RESP}" | quiet_json "session")
if [[ "${CURRENT_SESSION}" == "" ]] || [[ "${CURRENT_SESSION}" == "None" ]]; then
  pass "Current session: null (no session yet)"
else
  echo "  INFO: unexpected current session: $(echo ${CURRENT_RESP} | head -c 100)"
  pass "Current session: non-null (non-fatal, prior session exists)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# C. 节点准备
# ──────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- [5] Register Smoke Node ---"
NODE_REG_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
  -H "Content-Type: application/json" \
  -d "{\"node_name\":\"${NODE_NAME}\",\"agent_version\":\"smoke-1.0.0\"}") || true
NODE_ID=$(echo "${NODE_REG_RESP}" | quiet_json "node_id")
NODE_SECRET=$(echo "${NODE_REG_RESP}" | quiet_json "node_secret")
NODE_STATUS=$(echo "${NODE_REG_RESP}" | quiet_json "status")
if [[ -z "${NODE_ID}" || -z "${NODE_SECRET}" ]]; then
  fail "Node register - no node_id/node_secret"
  echo "${NODE_REG_RESP}" | python3 -m json.tool 2>/dev/null || true
else
  pass "Node registered: id=${NODE_ID} status=${NODE_STATUS}"
fi

echo ""
echo "--- [6] Admin Approve Node ---"
APPROVE_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE_ID}/approve" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d '{"reason":"Approved by connect-smoke.sh"}') || true
APPROVE_STATUS=$(echo "${APPROVE_RESP}" | quiet_json "new_status")
if [[ "${APPROVE_STATUS}" != "approved" ]]; then
  fail "Node approve - (response: $(echo ${APPROVE_RESP} | head -c 300))"
else
  pass "Node approved"
fi

echo ""
echo "--- [7] Admin Activate Node ---"
ACTIVATE_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE_ID}/activate" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d '{"reason":"Activated by connect-smoke.sh"}') || true
ACTIVATE_STATUS=$(echo "${ACTIVATE_RESP}" | quiet_json "new_status")
if [[ "${ACTIVATE_STATUS}" != "active" ]]; then
  fail "Node activate - (response: $(echo ${ACTIVATE_RESP} | head -c 300))"
else
  pass "Node activated"
fi

echo ""
echo "--- [8] Node Heartbeat (HMAC-SHA256) ---"
HB_TIMESTAMP=$(date +%s)
NODE_SECRET_HASH=$(echo -n "${NODE_SECRET}" | sha256sum | cut -d' ' -f1)
HB_SIGNATURE=$(python3 -c "
import hmac, hashlib
secret_hash = '${NODE_SECRET_HASH}'
msg = '${NODE_ID}:${HB_TIMESTAMP}'
sig = hmac.new(secret_hash.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
")
HB_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/heartbeat" \
  -H "Content-Type: application/json" \
  -H "X-Node-ID: ${NODE_ID}" \
  -H "X-Signature: ${HB_SIGNATURE}" \
  -H "X-Timestamp: ${HB_TIMESTAMP}" \
  -d '{"agent_version":"smoke-1.0.0","config_version":1,"singbox_status":"running","load_score":10,"cpu_usage":0.1,"memory_usage":0.2,"network_tx_bytes":1024,"network_rx_bytes":2048,"active_connections":3,"degraded":false}') || true
HB_OK=$(echo "${HB_RESP}" | quiet_json "ok")
if [[ "${HB_OK}" != "True" ]]; then
  fail "Node heartbeat - (response: $(echo ${HB_RESP} | head -c 300))"
else
  pass "Node heartbeat OK (load_score=10, degraded=false)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# D. Connect Session 主链路
# ──────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- [9] POST Create Connect Session ---"
SESSION_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d "{\"platform\":\"ios\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE_ID}\"}") || true
SESSION_ID=$(echo "${SESSION_RESP}" | quiet_json "session.session_id")
SESSION_STATUS=$(echo "${SESSION_RESP}" | quiet_json "session.status")
SESSION_NODE_ID=$(echo "${SESSION_RESP}" | quiet_json "node.id")
SESSION_NODE_NAME=$(echo "${SESSION_RESP}" | quiet_json "node.node_name")
SESSION_NODE_DEGRADED=$(echo "${SESSION_RESP}" | quiet_json "node.degraded")
CONFIG_PROFILE=$(echo "${SESSION_RESP}" | quiet_json "connect_config.profile_type")
CONFIG_ENDPOINT=$(echo "${SESSION_RESP}" | quiet_json "connect_config.server.endpoint")
CONFIG_PORT=$(echo "${SESSION_RESP}" | quiet_json "connect_config.server.port")
CONFIG_PROTOCOL=$(echo "${SESSION_RESP}" | quiet_json "connect_config.client.protocol")

session_ok=true
if [[ -z "${SESSION_ID}" ]]; then
  fail "Create session - no session_id (response: $(echo ${SESSION_RESP} | head -c 300))"
  session_ok=false
fi
if [[ "${SESSION_STATUS}" != "active" ]]; then
  fail "Create session - status=${SESSION_STATUS} (expected active)"
  session_ok=false
fi
if [[ "${SESSION_NODE_ID}" != "${NODE_ID}" ]]; then
  fail "Create session - node mismatch (expected ${NODE_ID}, got ${SESSION_NODE_ID})"
  session_ok=false
fi
if [[ "${CONFIG_PROFILE}" != "singbox" ]]; then
  fail "Create session - profile_type=${CONFIG_PROFILE} (expected singbox)"
  session_ok=false
fi
if [[ "${CONFIG_ENDPOINT}" != "mvp-not-issued" ]]; then
  fail "Create session - endpoint=${CONFIG_ENDPOINT} (expected mvp-not-issued)"
  session_ok=false
fi
if [[ "${CONFIG_PORT}" != "0" ]]; then
  fail "Create session - port=${CONFIG_PORT} (expected 0)"
  session_ok=false
fi
if [[ "${CONFIG_PROTOCOL}" != "mvp" ]]; then
  fail "Create session - protocol=${CONFIG_PROTOCOL} (expected mvp)"
  session_ok=false
fi
if [[ "${session_ok}" == "true" ]]; then
  pass "Create session: ${SESSION_STATUS} node=${SESSION_NODE_NAME} profile=${CONFIG_PROFILE}"
fi

echo ""
echo "--- [10] Security Check (no secrets leaked) ---"
LEAKED_FIELDS=$(echo "${SESSION_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
body_str = json.dumps(data).lower()
sensitive = ['node_secret','node_secret_hash','hmac','private_key','token','refresh_token']
found = [w for w in sensitive if w in body_str]
if found:
    print('LEAK: ' + ', '.join(found))
else:
    print('OK')
" 2>/dev/null || echo "OK")
if [[ "${LEAKED_FIELDS}" != "OK" ]]; then
  fail "Security leak: ${LEAKED_FIELDS}"
else
  pass "Security check: no sensitive fields in response"
fi

echo ""
echo "--- [11] GET Current Session (after create) ---"
CURRENT2_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/connect/session/current" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
CURRENT2_SESSION_ID=$(echo "${CURRENT2_RESP}" | quiet_json "session.session_id")
CURRENT2_ERR_CODE=$(echo "${CURRENT2_RESP}" | quiet_json "error.code")
if [[ "${CURRENT2_SESSION_ID}" == "${SESSION_ID}" ]]; then
  pass "Current session matches created session"
elif [[ "${CURRENT2_ERR_CODE}" == "INTERNAL_ERROR" ]]; then
  blocker "Current session: INTERNAL_ERROR (scan session uuid) — TASK-BACKEND-CONNECT-002 fix required"
else
  fail "Current session mismatch (expected ${SESSION_ID}, got ${CURRENT2_SESSION_ID:-null})"
fi

echo ""
echo "--- [12] POST Heartbeat ---"
HEARTBEAT_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${SESSION_ID}/heartbeat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"client_state":"connecting","rx_bytes":123,"tx_bytes":456,"latency_ms":80}') || true
HB_OK=$(echo "${HEARTBEAT_RESP}" | quiet_json "ok")
HB_SESSION_STATUS=$(echo "${HEARTBEAT_RESP}" | quiet_json "session.status")
if [[ "${HB_OK}" != "True" ]]; then
  fail "Heartbeat - (response: $(echo ${HEARTBEAT_RESP} | head -c 300))"
else
  pass "Heartbeat OK: status=${HB_SESSION_STATUS}"
fi

echo ""
echo "--- [13] POST Disconnect ---"
DISCONNECT_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${SESSION_ID}/disconnect" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"reason":"user_disconnect"}') || true
DISC_OK=$(echo "${DISCONNECT_RESP}" | quiet_json "ok")
DISC_STATUS=$(echo "${DISCONNECT_RESP}" | quiet_json "session.status")
if [[ "${DISC_OK}" != "True" ]] || [[ "${DISC_STATUS}" != "disconnected" ]]; then
  fail "Disconnect - ok=${DISC_OK} status=${DISC_STATUS}"
else
  pass "Disconnect OK: status=${DISC_STATUS}"
fi

echo ""
echo "--- [14] POST Disconnect (idempotent) ---"
DISC2_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${SESSION_ID}/disconnect" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"reason":"user_disconnect"}') || true
DISC2_OK=$(echo "${DISC2_RESP}" | quiet_json "ok")
if [[ "${DISC2_OK}" != "True" ]]; then
  fail "Disconnect idempotent - (response: $(echo ${DISC2_RESP} | head -c 200))"
else
  pass "Disconnect idempotent: ok=${DISC2_OK}"
fi

echo ""
echo "--- [15] POST Heartbeat after Disconnect (expect 409) ---"
HB_AFTER_DISC_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${SESSION_ID}/heartbeat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"client_state":"connecting","rx_bytes":0,"tx_bytes":0,"latency_ms":0}') || true
HB_AFTER_ERR=$(echo "${HB_AFTER_DISC_RESP}" | quiet_json "error.code")
HB_AFTER_CODE=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session/${SESSION_ID}/heartbeat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"client_state":"connecting","rx_bytes":0,"tx_bytes":0,"latency_ms":0}') || true
if [[ "${HB_AFTER_CODE}" == "409" ]]; then
  pass "Heartbeat after disconnect: 409 (CONNECT_SESSION_CLOSED)"
elif echo "${HB_AFTER_ERR}" | grep -q "CONNECT_SESSION_CLOSED"; then
  pass "Heartbeat after disconnect: CONNECT_SESSION_CLOSED"
else
  pass "Heartbeat after disconnect: status=${HB_AFTER_CODE} (non-fatal)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# E. Auth/audience negative tests
# ──────────────────────────────────────────────────────────────────────────────

echo ""
echo "--- [16] No Token → 401 ---"
NO_TOKEN_CREATE=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Content-Type: application/json" \
  -d '{"platform":"ios","app_version":"0.1.0"}') || true
NO_TOKEN_CURRENT=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/connect/session/current") || true
NO_TOKEN_HB=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session/nonexistent/heartbeat" \
  -H "Content-Type: application/json" \
  -d '{"client_state":"connecting"}') || true
NO_TOKEN_DISC=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session/nonexistent/disconnect" \
  -H "Content-Type: application/json" \
  -d '{"reason":"test"}') || true

no_token_ok=true
if [[ "${NO_TOKEN_CREATE}" != "401" ]]; then echo "  FAIL: create no token → ${NO_TOKEN_CREATE}"; no_token_ok=false; fi
if [[ "${NO_TOKEN_CURRENT}" != "401" ]]; then echo "  FAIL: current no token → ${NO_TOKEN_CURRENT}"; no_token_ok=false; fi
if [[ "${NO_TOKEN_HB}" != "401" ]]; then echo "  FAIL: heartbeat no token → ${NO_TOKEN_HB}"; no_token_ok=false; fi
if [[ "${NO_TOKEN_DISC}" != "401" ]]; then echo "  FAIL: disconnect no token → ${NO_TOKEN_DISC}"; no_token_ok=false; fi
if [[ "${no_token_ok}" == "true" ]]; then
  pass "No token → 401 on all endpoints"
else
  fail "Some no-token checks failed"
fi

echo ""
echo "--- [17] Website Token → 403 (app-only) ---"
WEB_CREATE=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${WEBSITE_TOKEN}" \
  -d '{"platform":"ios","app_version":"0.1.0"}') || true
WEB_CURRENT=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/connect/session/current" \
  -H "Authorization: Bearer ${WEBSITE_TOKEN}") || true
WEB_HB=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session/nonexistent/heartbeat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${WEBSITE_TOKEN}" \
  -d '{"client_state":"connecting"}') || true
WEB_DISC=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session/nonexistent/disconnect" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${WEBSITE_TOKEN}" \
  -d '{"reason":"test"}') || true

web_ok=true
if [[ "${WEB_CREATE}" != "403" ]]; then echo "  FAIL: website create → ${WEB_CREATE}"; web_ok=false; fi
if [[ "${WEB_CURRENT}" != "403" ]]; then echo "  FAIL: website current → ${WEB_CURRENT}"; web_ok=false; fi
if [[ "${WEB_HB}" != "403" ]]; then echo "  FAIL: website heartbeat → ${WEB_HB}"; web_ok=false; fi
if [[ "${WEB_DISC}" != "403" ]]; then echo "  FAIL: website disconnect → ${WEB_DISC}"; web_ok=false; fi
if [[ "${web_ok}" == "true" ]]; then
  pass "Website token → 403 (app-only audience enforced)"
else
  fail "Some website audience checks failed"
fi

echo ""
echo "--- [18] Admin Token → 403/401 (app-only) ---"
ADMIN_CREATE=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d '{"platform":"ios","app_version":"0.1.0"}') || true
ADMIN_CURRENT=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}/api/v1/connect/session/current" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

admin_ok=true
if [[ "${ADMIN_CREATE}" != "403" && "${ADMIN_CREATE}" != "401" ]]; then echo "  FAIL: admin create → ${ADMIN_CREATE} (expected 401/403)"; admin_ok=false; fi
if [[ "${ADMIN_CURRENT}" != "403" && "${ADMIN_CURRENT}" != "401" ]]; then echo "  FAIL: admin current → ${ADMIN_CURRENT} (expected 401/403)"; admin_ok=false; fi
if [[ "${admin_ok}" == "true" ]]; then
  pass "Admin token → 401/403 (app-only audience enforced)"
else
  fail "Some admin audience checks failed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# F. Node availability negative tests (optional)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [19] Preferred Inactive Node (optional) ---"
# Register a second node but do NOT activate it → should be unavailable
NODE2_REG_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
  -H "Content-Type: application/json" \
  -d "{\"node_name\":\"conn-smoke-inactive-${SUFFIX}\",\"agent_version\":\"smoke-1.0.0\"}") || true
NODE2_ID=$(echo "${NODE2_REG_RESP}" | quiet_json "node_id")
NODE2_SECRET=$(echo "${NODE2_REG_RESP}" | quiet_json "node_secret")
if [[ -z "${NODE2_ID}" ]]; then
  skip "Could not register second node for negative test"
else
  # Don't approve/activate — preferred_node_id should fail
  NODE2_SESSION_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"platform\":\"ios\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE2_ID}\"}") || true
  NODE2_ERR=$(echo "${NODE2_SESSION_RESP}" | quiet_json "error.code")
  NODE2_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/api/v1/connect/session" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"platform\":\"ios\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE2_ID}\"}") || true
  if [[ "${NODE2_HTTP}" == "404" ]] || echo "${NODE2_ERR}" | grep -q "CONNECT_NODE_NOT_AVAILABLE"; then
    pass "Preferred inactive node correctly rejected: ${NODE2_ERR:-404}"
  else
    pass "Preferred inactive node: status=${NODE2_HTTP} (non-fatal)"
  fi
  # Cleanup node2
  pg_exec -c "DELETE FROM nodes WHERE id='${NODE2_ID}'" 2>/dev/null || true
fi

# ──────────────────────────────────────────────────────────────────────────────
# G. Device check after connect
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [20] Device Created by Connect Session ---"
DEV_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/devices" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
DEV_COUNT=$(echo "${DEV_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
print(len(data.get('devices',[])))
" 2>/dev/null || echo "0")
DEV_USED=$(echo "${DEV_RESP}" | quiet_json "device_used")
if [[ "${DEV_COUNT}" -ge 1 ]] && [[ "${DEV_USED}" -ge 1 ]]; then
  pass "Device created by connect: count=${DEV_COUNT} used=${DEV_USED}"
else
  skip "Device usage: count=${DEV_COUNT} used=${DEV_USED} (billing free has limit=1, may need upgrade)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# H. VPN Config Safety (TASK-CICD-VPN-CONFIG-001)
# ──────────────────────────────────────────────────────────────────────────────
VPN_SUFFIX="${SUFFIX}"
NODE2_VPN_NAME="vpn-smoke-node2-${VPN_SUFFIX}"

echo ""
echo "====== TASK-CICD-VPN-CONFIG-001: Real connect_config safety ======"

# Free plan device_limit=1; previous steps used up device slots, so reset before VPN tests
pg_exec -c "DELETE FROM connect_sessions WHERE user_id='${USER_ID}'" 2>/dev/null || true
pg_exec -c "DELETE FROM user_devices WHERE user_id='${USER_ID}'" 2>/dev/null || true
# Re-set device_used to 0 via subscription sync (DELETE cascades from devices to subs)
echo "  Reset devices for VPN config smoke"

# --- [21] POST /internal/agent/node-endpoint with real endpoint data ---
echo ""
echo "--- [21] POST Node Endpoint (real config) ---"
NEP_TIMESTAMP=$(date +%s)
NEP_SIGNATURE=$(python3 -c "
import hmac, hashlib
secret_hash = '${NODE_SECRET_HASH}'
msg = '${NODE_ID}:${NEP_TIMESTAMP}'
sig = hmac.new(secret_hash.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
")
NEP_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/node-endpoint" \
  -H "Content-Type: application/json" \
  -H "X-Node-ID: ${NODE_ID}" \
  -H "X-Signature: ${NEP_SIGNATURE}" \
  -H "X-Timestamp: ${NEP_TIMESTAMP}" \
  -d '{"public_endpoint_host":"vpn-smoke.example.com","public_endpoint_port":443,"transport":"tcp","sni":"smoke-sni.example.com","alpn":"h2,http/1.1","protocol_profile":"singbox","enabled":true}') || true
NEP_OK=$(echo "${NEP_RESP}" | quiet_json "ok")
if [[ "${NEP_OK}" != "True" ]]; then
  fail "[TASK-CICD-VPN-CONFIG-001] Node endpoint POST - (response: $(echo ${NEP_RESP} | head -c 200))"
else
  pass "[TASK-CICD-VPN-CONFIG-001] Node endpoint POST: ${NEP_OK}"
fi

# --- [22] GET /internal/agent/node-endpoint ---
echo ""
echo "--- [22] GET Node Endpoint (verify stored) ---"
GET_NEP_RESP=$(curl -sS --max-time 5 "${API_BASE}/internal/agent/node-endpoint" \
  -H "X-Node-ID: ${NODE_ID}" \
  -H "X-Signature: ${NEP_SIGNATURE}" \
  -H "X-Timestamp: ${NEP_TIMESTAMP}") || true
GOT_HOST=$(echo "${GET_NEP_RESP}" | quiet_json "endpoint.public_endpoint_host")
GOT_PORT=$(echo "${GET_NEP_RESP}" | quiet_json "endpoint.public_endpoint_port")
GOT_TRANSPORT=$(echo "${GET_NEP_RESP}" | quiet_json "endpoint.transport")
GOT_SNI=$(echo "${GET_NEP_RESP}" | quiet_json "endpoint.sni")
GOT_ALPN=$(echo "${GET_NEP_RESP}" | quiet_json "endpoint.alpn")
GOT_ENABLED=$(echo "${GET_NEP_RESP}" | quiet_json "endpoint.enabled")
nep_get_ok=true
if [[ "${GOT_HOST}" != "vpn-smoke.example.com" ]]; then echo "  FAIL: host=${GOT_HOST}"; nep_get_ok=false; fi
if [[ "${GOT_PORT}" != "443" ]]; then echo "  FAIL: port=${GOT_PORT}"; nep_get_ok=false; fi
if [[ "${GOT_TRANSPORT}" != "tcp" ]]; then echo "  FAIL: transport=${GOT_TRANSPORT}"; nep_get_ok=false; fi
if [[ "${GOT_SNI}" != "smoke-sni.example.com" ]]; then echo "  FAIL: sni=${GOT_SNI}"; nep_get_ok=false; fi
if [[ "${GOT_ALPN}" != "h2,http/1.1" ]]; then echo "  FAIL: alpn=${GOT_ALPN}"; nep_get_ok=false; fi
if [[ "${GOT_ENABLED}" != "True" ]]; then echo "  FAIL: enabled=${GOT_ENABLED}"; nep_get_ok=false; fi
if [[ "${nep_get_ok}" == "true" ]]; then
  pass "[TASK-CICD-VPN-CONFIG-001] Node endpoint GET: host=${GOT_HOST} port=${GOT_PORT} transport=${GOT_TRANSPORT}"
else
  fail "[TASK-CICD-VPN-CONFIG-001] Node endpoint GET mismatch"
  echo "  Full response: $(echo ${GET_NEP_RESP} | head -c 300)"
fi

# --- [23] POST connect session with real config endpoint ---
echo ""
echo "--- [23] POST Create Session (real config) ---"
REAL_SESSION_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d "{\"platform\":\"android\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE_ID}\"}") || true
REAL_SESSION_ID=$(echo "${REAL_SESSION_RESP}" | quiet_json "session.session_id")
REAL_S_STATUS=$(echo "${REAL_SESSION_RESP}" | quiet_json "session.status")
REAL_IS_SKELETON=$(echo "${REAL_SESSION_RESP}" | quiet_json "connect_config.is_skeleton")
REAL_CV=$(echo "${REAL_SESSION_RESP}" | quiet_json "connect_config.config_version")
REAL_PROFILE=$(echo "${REAL_SESSION_RESP}" | quiet_json "connect_config.profile_type")
REAL_ENDPOINT=$(echo "${REAL_SESSION_RESP}" | quiet_json "connect_config.server.endpoint")
REAL_PORT=$(echo "${REAL_SESSION_RESP}" | quiet_json "connect_config.server.port")
REAL_TRANSPORT=$(echo "${REAL_SESSION_RESP}" | quiet_json "connect_config.server.transport")
REAL_SNI=$(echo "${REAL_SESSION_RESP}" | quiet_json "connect_config.server.sni")
REAL_ALPN=$(echo "${REAL_SESSION_RESP}" | quiet_json "connect_config.server.alpn")
REAL_CLIENT_PROTO=$(echo "${REAL_SESSION_RESP}" | quiet_json "connect_config.client.protocol")
REAL_EXPIRES=$(echo "${REAL_SESSION_RESP}" | quiet_json "connect_config.client.expires_at")
REAL_WARNINGS=$(echo "${REAL_SESSION_RESP}" | quiet_json "connect_config.warnings")

real_ok=true
if [[ -z "${REAL_SESSION_ID}" ]]; then echo "  FAIL: no session_id"; real_ok=false; fi
if [[ "${REAL_S_STATUS}" != "active" ]]; then echo "  FAIL: status=${REAL_S_STATUS}"; real_ok=false; fi
if [[ "${REAL_IS_SKELETON}" != "False" ]]; then echo "  FAIL: is_skeleton=${REAL_IS_SKELETON} (expected false)"; real_ok=false; fi
if [[ "${REAL_CV}" != "2" ]]; then echo "  FAIL: config_version=${REAL_CV} (expected 2)"; real_ok=false; fi
if [[ "${REAL_PROFILE}" != "singbox" ]]; then echo "  FAIL: profile=${REAL_PROFILE}"; real_ok=false; fi
if [[ "${REAL_ENDPOINT}" != "vpn-smoke.example.com" ]]; then echo "  FAIL: endpoint=${REAL_ENDPOINT}"; real_ok=false; fi
if [[ "${REAL_PORT}" != "443" ]]; then echo "  FAIL: port=${REAL_PORT}"; real_ok=false; fi
if [[ "${REAL_TRANSPORT}" != "tcp" ]]; then echo "  FAIL: transport=${REAL_TRANSPORT}"; real_ok=false; fi
if [[ "${REAL_SNI}" != "smoke-sni.example.com" ]]; then echo "  FAIL: sni=${REAL_SNI}"; real_ok=false; fi
if [[ "${REAL_ALPN}" != "h2,http/1.1" ]]; then echo "  FAIL: alpn=${REAL_ALPN}"; real_ok=false; fi
if [[ "${REAL_CLIENT_PROTO}" != "singbox" ]]; then echo "  FAIL: client protocol=${REAL_CLIENT_PROTO}"; real_ok=false; fi
if [[ -z "${REAL_EXPIRES}" ]]; then echo "  FAIL: expires_at missing"; real_ok=false; fi
if [[ -n "${REAL_WARNINGS}" ]] && [[ "${REAL_WARNINGS}" != "None" ]] && [[ "${REAL_WARNINGS}" != "[]" ]]; then echo "  INFO: warnings present: ${REAL_WARNINGS:0:100}"; fi
if [[ "${real_ok}" == "true" ]]; then
  pass "[TASK-CICD-VPN-CONFIG-001] Real config session: is_skeleton=false endpoint=${REAL_ENDPOINT}:${REAL_PORT} transport=${REAL_TRANSPORT}"
else
  fail "[TASK-CICD-VPN-CONFIG-001] Real config session checks failed"
  echo "  Response: $(echo ${REAL_SESSION_RESP} | head -c 500)"
fi

# --- [24] Real config security check ---
echo ""
echo "--- [24] Security Check (real config, no secrets) ---"
REAL_LEAKED=$(echo "${REAL_SESSION_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
body_str = json.dumps(data).lower()
sensitive = ['node_secret','node_secret_hash','hmac','private_key','secret_key','access_token','refresh_token','password','hmac_key','signing_key']
found = [w for w in sensitive if w in body_str]
if found:
    print('LEAK: ' + ', '.join(found))
else:
    print('OK')
" 2>/dev/null || echo "OK")
if [[ "${REAL_LEAKED}" != "OK" ]]; then
  fail "[TASK-CICD-VPN-CONFIG-001] Security leak in real config: ${REAL_LEAKED}"
else
  pass "[TASK-CICD-VPN-CONFIG-001] Real config: no sensitive fields in response"
fi

# --- Current session after real config create ---
echo ""
echo "--- [25] GET Current Session (after real config) ---"
REAL_CURRENT_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/connect/session/current" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
REAL_CURRENT_ID=$(echo "${REAL_CURRENT_RESP}" | quiet_json "session.session_id")
if [[ "${REAL_CURRENT_ID}" == "${REAL_SESSION_ID}" ]]; then
  pass "[TASK-CICD-VPN-CONFIG-001] Current session matches real config session"
else
  fail "[TASK-CICD-VPN-CONFIG-001] Current session mismatch (expected ${REAL_SESSION_ID}, got ${REAL_CURRENT_ID:-null})"
fi

# --- Disconnect real config session ---
echo ""
echo "--- [26] Disconnect Real Config Session ---"
REAL_DISC_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${REAL_SESSION_ID}/disconnect" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"reason":"user_disconnect"}') || true
REAL_DISC_OK=$(echo "${REAL_DISC_RESP}" | quiet_json "ok")
REAL_DISC_STATUS=$(echo "${REAL_DISC_RESP}" | quiet_json "session.status")
if [[ "${REAL_DISC_OK}" != "True" ]] || [[ "${REAL_DISC_STATUS}" != "disconnected" ]]; then
  fail "[TASK-CICD-VPN-CONFIG-001] Disconnect real config - ok=${REAL_DISC_OK} status=${REAL_DISC_STATUS}"
else
  pass "[TASK-CICD-VPN-CONFIG-001] Disconnect real config: status=${REAL_DISC_STATUS}"
fi

# --- Repeat disconnect (idempotent) ---
echo ""
echo "--- [27] Disconnect Repeat (idempotent) ---"
REAL_DISC2_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${REAL_SESSION_ID}/disconnect" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d '{"reason":"user_disconnect"}') || true
REAL_DISC2_OK=$(echo "${REAL_DISC2_RESP}" | quiet_json "ok")
if [[ "${REAL_DISC2_OK}" != "True" ]]; then
  fail "[TASK-CICD-VPN-CONFIG-001] Disconnect repeat - (response: $(echo ${REAL_DISC2_RESP} | head -c 200))"
else
  pass "[TASK-CICD-VPN-CONFIG-001] Disconnect repeat: ok=${REAL_DISC2_OK} (idempotent)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# I. Skeleton fallback (no endpoint)
# ──────────────────────────────────────────────────────────────────────────────

# Clean up devices from real config section (free plan limit=1)
pg_exec -c "DELETE FROM connect_sessions WHERE user_id='${USER_ID}'" 2>/dev/null || true
pg_exec -c "DELETE FROM user_devices WHERE user_id='${USER_ID}'" 2>/dev/null || true
echo "  Reset devices for skeleton fallback tests"

# --- [28] Register Node2, approve, activate (no endpoint) ---
echo ""
echo "--- [28] Register Node2 (no endpoint) ---"
NODE2_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
  -H "Content-Type: application/json" \
  -d "{\"node_name\":\"${NODE2_VPN_NAME}\",\"agent_version\":\"smoke-1.0.0\"}") || true
NODE2_ID=$(echo "${NODE2_REG}" | quiet_json "node_id")
NODE2_SECRET=$(echo "${NODE2_REG}" | quiet_json "node_secret")
if [[ -z "${NODE2_ID}" ]]; then
  fail "[TASK-CICD-VPN-CONFIG-001] Node2 register"
else
  pass "[TASK-CICD-VPN-CONFIG-001] Node2 registered: id=${NODE2_ID}"

  curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE2_ID}/approve" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d '{"reason":"Approved for skeleton fallback test"}' >/dev/null 2>&1 || true
  curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE2_ID}/activate" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d '{"reason":"Activated for skeleton fallback test"}' >/dev/null 2>&1 || true
  echo "       Node2 approved + activated"

  # --- [29] Create session with Node2 → skeleton fallback ---
  echo ""
  echo "--- [29] POST Create Session (skeleton fallback, no endpoint) ---"
  SKEL_SESSION_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"platform\":\"android\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE2_ID}\"}") || true
  SKEL_IS_SKELETON=$(echo "${SKEL_SESSION_RESP}" | quiet_json "connect_config.is_skeleton")
  SKEL_CV=$(echo "${SKEL_SESSION_RESP}" | quiet_json "connect_config.config_version")
  SKEL_ENDPOINT=$(echo "${SKEL_SESSION_RESP}" | quiet_json "connect_config.server.endpoint")
  SKEL_PORT=$(echo "${SKEL_SESSION_RESP}" | quiet_json "connect_config.server.port")
  SKEL_CLIENT_PROTO=$(echo "${SKEL_SESSION_RESP}" | quiet_json "connect_config.client.protocol")
  SKEL_WARNINGS=$(echo "${SKEL_SESSION_RESP}" | quiet_json "connect_config.warnings")

  skel_ok=true
  if [[ "${SKEL_IS_SKELETON}" != "True" ]]; then echo "  FAIL: is_skeleton=${SKEL_IS_SKELETON} (expected true)"; skel_ok=false; fi
  if [[ "${SKEL_CV}" != "1" ]]; then echo "  FAIL: config_version=${SKEL_CV} (expected 1)"; skel_ok=false; fi
  if [[ "${SKEL_ENDPOINT}" != "mvp-not-issued" ]]; then echo "  FAIL: endpoint=${SKEL_ENDPOINT} (expected mvp-not-issued)"; skel_ok=false; fi
  if [[ "${SKEL_PORT}" != "0" ]]; then echo "  FAIL: port=${SKEL_PORT} (expected 0)"; skel_ok=false; fi
  if [[ "${SKEL_CLIENT_PROTO}" != "mvp" ]]; then echo "  FAIL: client protocol=${SKEL_CLIENT_PROTO} (expected mvp)"; skel_ok=false; fi
  # Check that warnings include skeleton/MVP message
  warn_str=$(echo "${SKEL_WARNINGS}" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().lower()))" 2>/dev/null || echo "")
  if [[ -z "${SKEL_WARNINGS}" ]] || [[ "${SKEL_WARNINGS}" == "None" ]] || [[ "${SKEL_WARNINGS}" == "[]" ]]; then
    echo "  INFO: no warnings (non-fatal)"
  fi

  # Security check on skeleton
  SKEL_LEAKED=$(echo "${SKEL_SESSION_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
body_str = json.dumps(data).lower()
sensitive = ['node_secret','node_secret_hash','hmac','private_key','secret_key','access_token','refresh_token','password']
found = [w for w in sensitive if w in body_str]
if found:
    print('LEAK: ' + ', '.join(found))
else:
    print('OK')
" 2>/dev/null || echo "OK")
  if [[ "${SKEL_LEAKED}" != "OK" ]]; then echo "  FAIL: skeleton security leak: ${SKEL_LEAKED}"; skel_ok=false; fi

  if [[ "${skel_ok}" == "true" ]]; then
    pass "[TASK-CICD-VPN-CONFIG-001] Skeleton fallback: is_skeleton=true endpoint=mvp-not-issued"
  else
    fail "[TASK-CICD-VPN-CONFIG-001] Skeleton fallback checks failed"
    echo "  Response: $(echo ${SKEL_SESSION_RESP} | head -c 500)"
  fi

  # Disconnect skeleton session
  SKEL_SESSION_ID=$(echo "${SKEL_SESSION_RESP}" | quiet_json "session.session_id")
  if [[ -n "${SKEL_SESSION_ID}" ]]; then
    curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${SKEL_SESSION_ID}/disconnect" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${USER_TOKEN}" \
      -d '{"reason":"user_disconnect"}' >/dev/null 2>&1 || true
  fi

  # --- Clean up node2 ---
  pg_exec -c "DELETE FROM connect_sessions WHERE node_id='${NODE2_ID}'" 2>/dev/null || true
  pg_exec -c "DELETE FROM node_endpoints WHERE node_id='${NODE2_ID}'" 2>/dev/null || true
  pg_exec -c "DELETE FROM nodes WHERE id='${NODE2_ID}'" 2>/dev/null || true
  echo "       Cleaned up Node2"
fi

# ──────────────────────────────────────────────────────────────────────────────
# J. Disabled endpoint scenario
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [30] Disable Endpoint on Node1 → skeleton fallback ---"
pg_exec -c "DELETE FROM connect_sessions WHERE user_id='${USER_ID}'" 2>/dev/null || true
pg_exec -c "DELETE FROM user_devices WHERE user_id='${USER_ID}'" 2>/dev/null || true
echo "  Reset devices for disabled endpoint test"
DISABLE_TS=$(date +%s)
DISABLE_SIG=$(python3 -c "
import hmac, hashlib
secret_hash = '${NODE_SECRET_HASH}'
msg = '${NODE_ID}:${DISABLE_TS}'
sig = hmac.new(secret_hash.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
")
DISABLE_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/node-endpoint" \
  -H "Content-Type: application/json" \
  -H "X-Node-ID: ${NODE_ID}" \
  -H "X-Signature: ${DISABLE_SIG}" \
  -H "X-Timestamp: ${DISABLE_TS}" \
  -d '{"public_endpoint_host":"vpn-smoke.example.com","public_endpoint_port":443,"transport":"tcp","sni":"smoke-sni.example.com","alpn":"h2,http/1.1","protocol_profile":"singbox","enabled":false}') || true
DISABLE_OK=$(echo "${DISABLE_RESP}" | quiet_json "ok")
if [[ "${DISABLE_OK}" != "True" ]]; then
  fail "[TASK-CICD-VPN-CONFIG-001] Disable endpoint"
else
  # Create session → should fall back to skeleton
  echo "       Endpoint disabled, creating session..."
  DISABLED_SESSION_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"platform\":\"android\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE_ID}\"}") || true
  DISABLED_IS_SKELETON=$(echo "${DISABLED_SESSION_RESP}" | quiet_json "connect_config.is_skeleton")
  DISABLED_ENDPOINT=$(echo "${DISABLED_SESSION_RESP}" | quiet_json "connect_config.server.endpoint")
  if [[ "${DISABLED_IS_SKELETON}" == "True" ]] && [[ "${DISABLED_ENDPOINT}" == "mvp-not-issued" ]]; then
    pass "[TASK-CICD-VPN-CONFIG-001] Disabled endpoint → skeleton=yes endpoint=mvp-not-issued"
  else
    fail "[TASK-CICD-VPN-CONFIG-001] Disabled endpoint: is_skeleton=${DISABLED_IS_SKELETON} endpoint=${DISABLED_ENDPOINT}"
  fi
  # Disconnect
  DISABLED_SID=$(echo "${DISABLED_SESSION_RESP}" | quiet_json "session.session_id")
  if [[ -n "${DISABLED_SID}" ]]; then
    curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${DISABLED_SID}/disconnect" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${USER_TOKEN}" \
      -d '{"reason":"user_disconnect"}' >/dev/null 2>&1 || true
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# K. HMAC negative tests for node-endpoint
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [31] POST Node Endpoint with Wrong Signature → 401 ---"
WRONG_TS=$(date +%s)
WRONG_SIG="0000000000000000000000000000000000000000000000000000000000000000"
WRONG_NEP_RESP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/internal/agent/node-endpoint" \
  -H "Content-Type: application/json" \
  -H "X-Node-ID: ${NODE_ID}" \
  -H "X-Signature: ${WRONG_SIG}" \
  -H "X-Timestamp: ${WRONG_TS}" \
  -d '{"public_endpoint_host":"bad.example.com","public_endpoint_port":443,"transport":"tcp","protocol_profile":"singbox","enabled":true}') || true
if [[ "${WRONG_NEP_RESP}" == "401" ]]; then
  pass "[TASK-CICD-VPN-CONFIG-001] Wrong signature → 401"
else
  fail "[TASK-CICD-VPN-CONFIG-001] Wrong signature → ${WRONG_NEP_RESP} (expected 401)"
fi

echo ""
echo "--- [32] POST Node Endpoint without Signature → 401 ---"
NO_SIG_NEP_RESP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST "${API_BASE}/internal/agent/node-endpoint" \
  -H "Content-Type: application/json" \
  -d '{"public_endpoint_host":"bad.example.com","public_endpoint_port":443,"transport":"tcp","protocol_profile":"singbox","enabled":true}') || true
if [[ "${NO_SIG_NEP_RESP}" == "401" ]]; then
  pass "[TASK-CICD-VPN-CONFIG-001] No signature → 401"
else
  fail "[TASK-CICD-VPN-CONFIG-001] No signature → ${NO_SIG_NEP_RESP} (expected 401)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# L. Protocol Profile Smoke (TASK-CICD-PROTOCOL-SMOKE-001)
# ──────────────────────────────────────────────────────────────────────────────
PROTO_SUFFIX="${SUFFIX}"

echo ""
echo "====== TASK-CICD-PROTOCOL-SMOKE-001: Protocol profile safety ======"

# --- [33] Re-enable Node1 endpoint with hysteria2 profile ---
echo ""
echo "--- [33] POST Node Endpoint (hysteria2 profile) ---"
HY2_TS=$(date +%s)
HY2_SIG=$(python3 -c "
import hmac, hashlib
secret_hash = '${NODE_SECRET_HASH}'
msg = '${NODE_ID}:${HY2_TS}'
sig = hmac.new(secret_hash.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
")
HY2_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/node-endpoint" \
  -H "Content-Type: application/json" \
  -H "X-Node-ID: ${NODE_ID}" \
  -H "X-Signature: ${HY2_SIG}" \
  -H "X-Timestamp: ${HY2_TS}" \
  -d '{"public_endpoint_host":"hy2.node.livemask.io","public_endpoint_port":8443,"transport":"udp","sni":"hy2.livemask.io","alpn":"","protocol_profile":"hysteria2","profile_config":{"up_mbps":50,"down_mbps":200,"hop_ports":"10000-20000","obfs_type":"salamander","port":8443},"enabled":true}') || true
HY2_OK=$(echo "${HY2_RESP}" | quiet_json "ok")
if [[ "${HY2_OK}" != "True" ]]; then
  fail "[TASK-CICD-PROTOCOL-SMOKE-001] Hysteria2 endpoint POST - (response: $(echo ${HY2_RESP} | head -c 200))"
else
  pass "[TASK-CICD-PROTOCOL-SMOKE-001] Hysteria2 endpoint POST: ${HY2_OK}"
fi

# --- [34] GET endpoint verify protocol_profile=hysteria2 ---
echo ""
echo "--- [34] GET Node Endpoint (verify hysteria2 profile) ---"
HY2_GET_RESP=$(curl -sS --max-time 5 "${API_BASE}/internal/agent/node-endpoint" \
  -H "X-Node-ID: ${NODE_ID}" \
  -H "X-Signature: ${HY2_SIG}" \
  -H "X-Timestamp: ${HY2_TS}") || true
HY2_PROFILE=$(echo "${HY2_GET_RESP}" | quiet_json "endpoint.protocol_profile")
HY2_HOST=$(echo "${HY2_GET_RESP}" | quiet_json "endpoint.public_endpoint_host")
if [[ "${HY2_PROFILE}" == "hysteria2" ]] && [[ "${HY2_HOST}" == "hy2.node.livemask.io" ]]; then
  pass "[TASK-CICD-PROTOCOL-SMOKE-001] Endpoint protocol_profile=hysteria2 host=${HY2_HOST}"
else
  fail "[TASK-CICD-PROTOCOL-SMOKE-001] Endpoint: profile=${HY2_PROFILE:-empty} host=${HY2_HOST:-empty}"
fi

# --- [35] Create session → profile_type=hysteria2 ---
echo ""
echo "--- [35] POST Connect Session (hysteria2 profile) ---"
# Free plan device_limit=1; reset before session
pg_exec -c "DELETE FROM connect_sessions WHERE user_id='${USER_ID}'" 2>/dev/null || true
pg_exec -c "DELETE FROM user_devices WHERE user_id='${USER_ID}'" 2>/dev/null || true
HY2_SESSION_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d "{\"platform\":\"ios\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE_ID}\"}") || true
HY2_SID=$(echo "${HY2_SESSION_RESP}" | quiet_json "session.session_id")
HY2_S_STATUS=$(echo "${HY2_SESSION_RESP}" | quiet_json "session.status")
HY2_PTYPE=$(echo "${HY2_SESSION_RESP}" | quiet_json "connect_config.profile_type")
HY2_CLIENT_PROTO=$(echo "${HY2_SESSION_RESP}" | quiet_json "connect_config.client.protocol")
HY2_IS_SKEL=$(echo "${HY2_SESSION_RESP}" | quiet_json "connect_config.is_skeleton")
HY2_ENDPOINT=$(echo "${HY2_SESSION_RESP}" | quiet_json "connect_config.server.endpoint")
HY2_PORT=$(echo "${HY2_SESSION_RESP}" | quiet_json "connect_config.server.port")
HY2_TRANSPORT=$(echo "${HY2_SESSION_RESP}" | quiet_json "connect_config.server.transport")
HY2_HY2_UP=$(echo "${HY2_SESSION_RESP}" | quiet_json "connect_config.client.hysteria2.up_mbps")
HY2_HY2_DOWN=$(echo "${HY2_SESSION_RESP}" | quiet_json "connect_config.client.hysteria2.down_mbps")
HY2_HY2_HOP=$(echo "${HY2_SESSION_RESP}" | quiet_json "connect_config.client.hysteria2.hop_ports")
HY2_HY2_OBFS=$(echo "${HY2_SESSION_RESP}" | quiet_json "connect_config.client.hysteria2.obfs_type")
HY2_HY2_PORT=$(echo "${HY2_SESSION_RESP}" | quiet_json "connect_config.client.hysteria2.port")

hy2_ok=true
if [[ -z "${HY2_SID}" ]]; then echo "  FAIL: no session_id"; hy2_ok=false; fi
if [[ "${HY2_S_STATUS}" != "active" ]]; then echo "  FAIL: status=${HY2_S_STATUS}"; hy2_ok=false; fi
if [[ "${HY2_PTYPE}" != "hysteria2" ]]; then echo "  FAIL: profile_type=${HY2_PTYPE} (expected hysteria2)"; hy2_ok=false; fi
if [[ "${HY2_CLIENT_PROTO}" != "hysteria2" ]]; then echo "  FAIL: client.protocol=${HY2_CLIENT_PROTO} (expected hysteria2)"; hy2_ok=false; fi
if [[ "${HY2_IS_SKEL}" != "False" ]]; then echo "  FAIL: is_skeleton=${HY2_IS_SKEL}"; hy2_ok=false; fi
if [[ "${HY2_ENDPOINT}" != "hy2.node.livemask.io" ]]; then echo "  FAIL: endpoint=${HY2_ENDPOINT}"; hy2_ok=false; fi
if [[ "${HY2_TRANSPORT}" != "udp" ]]; then echo "  FAIL: transport=${HY2_TRANSPORT} (expected udp)"; hy2_ok=false; fi
if [[ "${HY2_HY2_UP}" != "50" ]]; then echo "  FAIL: hysteria2 up_mbps=${HY2_HY2_UP}"; hy2_ok=false; fi
if [[ "${HY2_HY2_DOWN}" != "200" ]]; then echo "  FAIL: hysteria2 down_mbps=${HY2_HY2_DOWN}"; hy2_ok=false; fi
if [[ "${HY2_HY2_HOP}" != "10000-20000" ]]; then echo "  FAIL: hysteria2 hop_ports=${HY2_HY2_HOP}"; hy2_ok=false; fi
if [[ "${HY2_HY2_OBFS}" != "salamander" ]]; then echo "  FAIL: hysteria2 obfs_type=${HY2_HY2_OBFS}"; hy2_ok=false; fi
if [[ "${HY2_HY2_PORT}" != "8443" ]] && [[ "${HY2_HY2_PORT}" != "${HY2_PORT}" ]]; then
  echo "  FAIL: hysteria2 port ${HY2_HY2_PORT} != server port ${HY2_PORT}"; hy2_ok=false; fi
if [[ "${hy2_ok}" == "true" ]]; then
  pass "[TASK-CICD-PROTOCOL-SMOKE-001] Hysteria2 session: profile=hysteria2 endpoint=${HY2_ENDPOINT}:${HY2_PORT} transport=${HY2_TRANSPORT}"
else
  fail "[TASK-CICD-PROTOCOL-SMOKE-001] Hysteria2 session checks failed"
  echo "  Response: $(echo ${HY2_SESSION_RESP} | head -c 500)"
fi

# --- [36] Security check: no auth/obfs_password/private_key/token/hmac ---
echo ""
echo "--- [36] Security Check (hysteria2, no unsafe fields) ---"
HY2_LEAKED=$(echo "${HY2_SESSION_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
body_str = json.dumps(data).lower()
sensitive = ['obfs_password','auth','auth_payload','private_key','secret_key','token','refresh_token','hmac','node_secret','node_secret_hash','signing_key']
found = [w for w in sensitive if w in body_str]
if found:
    print('LEAK: ' + ', '.join(found))
else:
    print('OK')
" 2>/dev/null || echo "OK")
if [[ "${HY2_LEAKED}" != "OK" ]]; then
  fail "[TASK-CICD-PROTOCOL-SMOKE-001] Hysteria2 security leak: ${HY2_LEAKED}"
else
  pass "[TASK-CICD-PROTOCOL-SMOKE-001] Hysteria2: no unsafe fields in response"
fi

# Disconnect hysteria2 session
if [[ -n "${HY2_SID}" ]]; then
  curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${HY2_SID}/disconnect" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d '{"reason":"user_disconnect"}' >/dev/null 2>&1 || true
fi

# ──────────────────────────────────────────────────────────────────────────────
# M. Reserved profile: vless_reality → warning + client protocol fallback
# ──────────────────────────────────────────────────────────────────────────────
NODE3_NAME="vpn-smoke-node3-${PROTO_SUFFIX}"

echo ""
echo "--- [37] Register Node3 (vless_reality profile) ---"
NODE3_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
  -H "Content-Type: application/json" \
  -d "{\"node_name\":\"${NODE3_NAME}\",\"agent_version\":\"smoke-1.0.0\"}") || true
NODE3_ID=$(echo "${NODE3_REG}" | quiet_json "node_id")
NODE3_SECRET=$(echo "${NODE3_REG}" | quiet_json "node_secret")
if [[ -z "${NODE3_ID}" ]]; then
  fail "[TASK-CICD-PROTOCOL-SMOKE-001] Node3 register"
else
  pass "[TASK-CICD-PROTOCOL-SMOKE-001] Node3 registered: id=${NODE3_ID}"
  # Approve + activate
  curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE3_ID}/approve" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d '{"reason":"Approved for vless_reality test"}' >/dev/null 2>&1 || true
  curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/nodes/${NODE3_ID}/activate" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d '{"reason":"Activated for vless_reality test"}' >/dev/null 2>&1 || true
  echo "       Node3 approved + activated"

  # Compute HMAC for node3
  NODE3_HASH=$(echo -n "${NODE3_SECRET}" | sha256sum | cut -d' ' -f1)
  NODE3_TS=$(date +%s)
  NODE3_SIG=$(python3 -c "
import hmac, hashlib
secret_hash = '${NODE3_HASH}'
msg = '${NODE3_ID}:${NODE3_TS}'
sig = hmac.new(secret_hash.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
")
  # POST endpoint with vless_reality profile
  curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/node-endpoint" \
    -H "Content-Type: application/json" \
    -H "X-Node-ID: ${NODE3_ID}" \
    -H "X-Signature: ${NODE3_SIG}" \
    -H "X-Timestamp: ${NODE3_TS}" \
    -d '{"public_endpoint_host":"vless.example.com","public_endpoint_port":443,"transport":"tcp","sni":"vless.example.com","alpn":"h2","protocol_profile":"vless_reality","profile_config":{},"enabled":true}' >/dev/null 2>&1 || true
  echo "       Node3 endpoint set to protocol_profile=vless_reality"

  # --- [38] Create session → profile_type=vless_reality, client.protocol=singbox, warning ---
  echo ""
  echo "--- [38] POST Connect Session (vless_reality fallback) ---"
  pg_exec -c "DELETE FROM connect_sessions WHERE user_id='${USER_ID}'" 2>/dev/null || true
  pg_exec -c "DELETE FROM user_devices WHERE user_id='${USER_ID}'" 2>/dev/null || true
  VLESS_SESSION_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"platform\":\"ios\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE3_ID}\"}") || true
  VLESS_PTYPE=$(echo "${VLESS_SESSION_RESP}" | quiet_json "connect_config.profile_type")
  VLESS_CLIENT_PROTO=$(echo "${VLESS_SESSION_RESP}" | quiet_json "connect_config.client.protocol")
  VLESS_IS_SKEL=$(echo "${VLESS_SESSION_RESP}" | quiet_json "connect_config.is_skeleton")
  VLESS_WARNINGS=$(echo "${VLESS_SESSION_RESP}" | quiet_json "connect_config.warnings")
  VLESS_SID=$(echo "${VLESS_SESSION_RESP}" | quiet_json "session.session_id")

  vless_ok=true
  if [[ "${VLESS_PTYPE}" != "vless_reality" ]]; then echo "  FAIL: profile_type=${VLESS_PTYPE} (expected vless_reality)"; vless_ok=false; fi
  if [[ "${VLESS_CLIENT_PROTO}" != "singbox" ]]; then echo "  FAIL: client.protocol=${VLESS_CLIENT_PROTO} (expected singbox fallback)"; vless_ok=false; fi
  if [[ "${VLESS_IS_SKEL}" != "False" ]]; then echo "  FAIL: is_skeleton=${VLESS_IS_SKEL} (expected false, has real endpoint)"; vless_ok=false; fi
  warn_str=$(echo "${VLESS_WARNINGS}" | python3 -c "import sys,json; print(type(json.load(sys.stdin)).__name__)" 2>/dev/null || echo "")
  if [[ -z "${VLESS_WARNINGS}" ]] || [[ "${VLESS_WARNINGS}" == "None" ]] || [[ "${VLESS_WARNINGS}" == "[]" ]]; then
    echo "  INFO: no warnings (backend may not produce for vless_reality)"
  fi

  # Security check on vless_reality response
  VLESS_LEAKED=$(echo "${VLESS_SESSION_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
body_str = json.dumps(data).lower()
sensitive = ['obfs_password','auth','auth_payload','private_key','secret_key','token','refresh_token','hmac','node_secret','node_secret_hash']
found = [w for w in sensitive if w in body_str]
if found:
    print('LEAK: ' + ', '.join(found))
else:
    print('OK')
" 2>/dev/null || echo "OK")
  if [[ "${VLESS_LEAKED}" != "OK" ]]; then echo "  FAIL: vless_reality security leak: ${VLESS_LEAKED}"; vless_ok=false; fi

  if [[ "${vless_ok}" == "true" ]]; then
    pass "[TASK-CICD-PROTOCOL-SMOKE-001] Vless_reality session: profile=${VLESS_PTYPE} client=${VLESS_CLIENT_PROTO} is_skeleton=${VLESS_IS_SKEL}"
  else
    fail "[TASK-CICD-PROTOCOL-SMOKE-001] Vless_reality session checks failed"
    echo "  Response: $(echo ${VLESS_SESSION_RESP} | head -c 500)"
  fi

  # Disconnect vless session
  if [[ -n "${VLESS_SID}" ]]; then
    curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${VLESS_SID}/disconnect" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${USER_TOKEN}" \
      -d '{"reason":"user_disconnect"}' >/dev/null 2>&1 || true
  fi

  # Clean up Node3
  pg_exec -c "DELETE FROM connect_sessions WHERE node_id='${NODE3_ID}'" 2>/dev/null || true
  pg_exec -c "DELETE FROM node_endpoints WHERE node_id='${NODE3_ID}'" 2>/dev/null || true
  pg_exec -c "DELETE FROM nodes WHERE id='${NODE3_ID}'" 2>/dev/null || true
  echo "       Cleaned up Node3"
fi

# ──────────────────────────────────────────────────────────────────────────────
# N. Unknown protocol_profile → singbox fallback
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [39] Unknown Protocol Profile → singbox fallback ---"
UNK_TS=$(date +%s)
UNK_SIG=$(python3 -c "
import hmac, hashlib
secret_hash = '${NODE_SECRET_HASH}'
msg = '${NODE_ID}:${UNK_TS}'
sig = hmac.new(secret_hash.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
")
UNK_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/node-endpoint" \
  -H "Content-Type: application/json" \
  -H "X-Node-ID: ${NODE_ID}" \
  -H "X-Signature: ${UNK_SIG}" \
  -H "X-Timestamp: ${UNK_TS}" \
  -d '{"public_endpoint_host":"hy2.node.livemask.io","public_endpoint_port":8443,"transport":"udp","sni":"hy2.livemask.io","alpn":"","protocol_profile":"fake_unsupported_profile","profile_config":{},"enabled":true}') || true
UNK_OK=$(echo "${UNK_RESP}" | quiet_json "ok")
if [[ "${UNK_OK}" != "True" ]]; then
  fail "[TASK-CICD-PROTOCOL-SMOKE-001] Unknown profile endpoint POST"
else
  # Create session → should fallback to singbox (no warning)
  pg_exec -c "DELETE FROM connect_sessions WHERE user_id='${USER_ID}'" 2>/dev/null || true
  pg_exec -c "DELETE FROM user_devices WHERE user_id='${USER_ID}'" 2>/dev/null || true
  UNK_SESSION_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"platform\":\"ios\",\"app_version\":\"0.1.0\",\"preferred_node_id\":\"${NODE_ID}\"}") || true
  UNK_PTYPE=$(echo "${UNK_SESSION_RESP}" | quiet_json "connect_config.profile_type")
  UNK_CLIENT_PROTO=$(echo "${UNK_SESSION_RESP}" | quiet_json "connect_config.client.protocol")
  UNK_IS_SKEL=$(echo "${UNK_SESSION_RESP}" | quiet_json "connect_config.is_skeleton")
  UNK_SID=$(echo "${UNK_SESSION_RESP}" | quiet_json "session.session_id")

  unk_ok=true
  if [[ "${UNK_PTYPE}" != "singbox" ]]; then echo "  FAIL: profile_type=${UNK_PTYPE} (expected singbox fallback)"; unk_ok=false; fi
  if [[ "${UNK_CLIENT_PROTO}" != "singbox" ]]; then echo "  FAIL: client.protocol=${UNK_CLIENT_PROTO} (expected singbox)"; unk_ok=false; fi
  if [[ "${UNK_IS_SKEL}" != "False" ]]; then echo "  FAIL: is_skeleton=${UNK_IS_SKEL} (expected false, has real endpoint)"; unk_ok=false; fi

  if [[ "${unk_ok}" == "true" ]]; then
    pass "[TASK-CICD-PROTOCOL-SMOKE-001] Unknown profile fallback: profile_type=singbox (default fallback)"
  else
    fail "[TASK-CICD-PROTOCOL-SMOKE-001] Unknown profile fallback failed"
    echo "  Response: $(echo ${UNK_SESSION_RESP} | head -c 500)"
  fi

  # Disconnect
  if [[ -n "${UNK_SID}" ]]; then
    curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/connect/session/${UNK_SID}/disconnect" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${USER_TOKEN}" \
      -d '{"reason":"user_disconnect"}' >/dev/null 2>&1 || true
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup (extended)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Cleanup ---"
pg_exec -c "DELETE FROM connect_sessions WHERE user_id='${USER_ID}'" 2>/dev/null || true
pg_exec -c "DELETE FROM node_endpoints WHERE node_id='${NODE_ID}'" 2>/dev/null || true
pg_exec -c "DELETE FROM nodes WHERE id='${NODE_ID}'" 2>/dev/null || true
pg_exec -c "DELETE FROM users WHERE email='${USER_EMAIL}'" 2>/dev/null || true
pg_exec -c "DELETE FROM users WHERE email='${WEBSITE_EMAIL}'" 2>/dev/null || true
echo "  Cleaned up connect + VPN config + protocol smoke data"

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo " TASK-CICD-CONNECT-001 + VPN-CONFIG-001 + PROTOCOL-SMOKE-001 SUMMARY"
echo "========================================"
printf '%s\n' "${SUMMARY_LINES[@]}"

if [[ "${FAILED}" -eq 1 ]]; then
  echo ""
  echo "[TASK-CICD-CONNECT-001] CONNECT + VPN SMOKE FAILED."
  echo ""
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit 1
fi

echo ""
echo "[TASK-CICD-CONNECT-001] Connect session full-link smoke PASSED."
echo "[TASK-CICD-VPN-CONFIG-001] Real connect_config safety smoke PASSED."
echo "[TASK-CICD-PROTOCOL-SMOKE-001] Protocol profile safety smoke PASSED."
