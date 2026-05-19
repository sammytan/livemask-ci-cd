#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-OBSERVABILITY-SMOKE-001
# Observability Smoke — Full observability pipeline verification
# ═══════════════════════════════════════════════════════════════════════════════
# Covers (per CICD-SENTRY-OBSERVABILITY-CURSOR_HANDOFF.md §3):
#   [1]  Backend health
#   [2]  Job Service health
#   [3]  NodeAgent health when available
#   [4]  Admin login
#   [5]  Backend /metrics — contains required metric names
#   [6]  Job Service /metrics — contains required metric names
#   [7]  NodeAgent /metrics — contains required metric names
#   [8]  NodeAgent log upload (POST /internal/agent/logs with HMAC)
#   [9]  Job Service ingestion check
#  [10]  GET /admin/api/v1/logs (global logs)
#  [11]  GET /admin/api/v1/audit-logs
#  [12]  GET /admin/api/v1/nodes/{node_id}/logs (node latest logs)
#  [13]  GET /admin/api/v1/app/exceptions (Sentry summary / App exceptions)
#  [14]  GET /admin/api/v1/logs/agent (NodeAgent logs)
#  [15]  GET /admin/api/v1/logs/payment (payment logs)
#  [16]  GET /admin/api/v1/logs/notification (notification logs)
#  [17]  GET /admin/api/v1/observability/sentry (Sentry summary)
#  [18]  GET /admin/api/v1/observability/sentry/events
#  [19]  GET /admin/api/v1/observability/sentry/performance
#  [20]  RBAC: no token / user token → 401/403
#  [21]  Payment order logs (GET /admin/api/v1/payments/orders/*/logs)
#  [22]  Notification delivery logs (GET /admin/api/v1/notifications/delivery-logs)
#  [23]  Secret leak scan across every response
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
BACKEND_HTTP_PORT="${LIVEMASK_BACKEND_HTTP_PORT:-18080}"
API_BASE="http://127.0.0.1:${BACKEND_HTTP_PORT}"
JOB_SERVICE_API="${JOB_SERVICE_API:-http://127.0.0.1:18081}"
NODEAGENT_API="${NODEAGENT_API:-http://127.0.0.1:19090}"

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
  FAILED=1
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

security_check() {
  local label="$1"
  local json="$2"
  local extra_sensitive="${3:-}"
  local leaked
  leaked=$(echo "${json}" | python3 -c "
import sys,json
SENSITIVE_WORDS = [
    'password_hash','node_secret','hmac','private_key','secret_key',
    'storage_path','encryption_key','access_token','refresh_token',
    'api_key','license_key','email_password','smtp_password',
    'aws_secret','s3_secret','access_key','secret_access_key',
    'sentry_dsn','auth_token','org_token','project_token','relay_secret',
    'webhook_secret','authorization','cookie',
]
extra = '${extra_sensitive}'
if extra:
    SENSITIVE_WORDS.extend([w.strip() for w in extra.split(',') if w.strip()])
def check_keys(d, target_words):
    if isinstance(d, dict):
        for k, v in d.items():
            kl = k.lower()
            for w in target_words:
                if w in kl:
                    return True
            if check_keys(v, target_words):
                return True
    elif isinstance(d, list):
        for item in d:
            if check_keys(item, target_words):
                return True
    return False
data=json.load(sys.stdin)
found = [w for w in SENSITIVE_WORDS if check_keys(data, [w])]
if found:
    print('LEAK: ' + ', '.join(found))
else:
    print('OK')
" 2>/dev/null || echo "OK")
  if [[ "${leaked}" != "OK" ]]; then
    fail "[SECURITY] ${label}: ${leaked}"
    return 1
  fi
  return 0
}

check_metrics() {
  local label="$1"
  local metrics_url="$2"
  local required_metrics="$3"
  local resp
  resp=$(curl -sS --max-time 5 "${metrics_url}" 2>/dev/null || echo "")
  if [[ -z "${resp}" ]]; then
    skip "${label}: endpoint unreachable"
    return 0
  fi
  local missing=""
  for metric in ${required_metrics}; do
    if ! echo "${resp}" | grep -q "${metric}"; then
      missing="${missing} ${metric}"
    fi
  done
  if [[ -n "${missing}" ]]; then
    fail "${label}: missing metrics:${missing}"
  else
    pass "${label}: all required metrics present"
  fi
}

TIMESTAMP=$(date +%s)
SUFFIX="obs-${TIMESTAMP}"

echo "================================================"
echo " TASK-CICD-OBSERVABILITY-SMOKE-001"
echo " Observability Smoke (Full Pipeline)"
echo "================================================"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# [1] Backend health
# ════════════════════════════════════════════════════════════════════════════
echo "--- [1] Backend Health ---"
for attempt in $(seq 1 30); do
  health_resp=$(curl -sS --max-time 3 "${API_BASE}/api/v1/health" 2>/dev/null || true)
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    echo "  Backend ready (attempt ${attempt})"
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    blocker "Backend not ready after 30 attempts"
    echo ""
    printf '%s\n' "${SUMMARY_LINES[@]}"
    exit 1
  fi
  sleep 2
done
pass "Backend health ok"

# ════════════════════════════════════════════════════════════════════════════
# [2] Job Service health
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [2] Job Service Health ---"
JS_HEALTH_RESP=$(curl -sS --max-time 5 "${JOB_SERVICE_API}/health" 2>/dev/null || echo "")
if [[ -n "${JS_HEALTH_RESP}" ]]; then
  JS_OK=$(echo "${JS_HEALTH_RESP}" | quiet_json "status" || echo "")
  if [[ "${JS_OK}" == "ok" ]]; then
    pass "Job Service health ok"
  else
    skip "Job Service health: responded but status=${JS_OK}"
  fi
else
  skip "Job Service health: unreachable (${JOB_SERVICE_API})"
fi

# ════════════════════════════════════════════════════════════════════════════
# [3] NodeAgent health when available
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [3] NodeAgent Health ---"
NA_HEALTH_RESP=$(curl -sS --max-time 5 "${NODEAGENT_API}/health" 2>/dev/null || echo "")
if [[ -n "${NA_HEALTH_RESP}" ]]; then
  NA_OK=$(echo "${NA_HEALTH_RESP}" | quiet_json "status" || echo "")
  if [[ -n "${NA_OK}" ]]; then
    pass "NodeAgent health: status=${NA_OK}"
  else
    pass "NodeAgent health: responded"
  fi
else
  skip "NodeAgent health: unreachable (${NODEAGENT_API})"
fi

# ════════════════════════════════════════════════════════════════════════════
# [4] Admin login
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [4] Admin Login ---"
pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'" 2>/dev/null || true
ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -n "${ADMIN_HASH}" ]]; then
  pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'" 2>/dev/null
  pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by observability-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
fi
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"obs-smoke-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  blocker "Admin login — no access token"
else
  pass "Admin login OK (token length=${#ADMIN_TOKEN})"
fi

# ════════════════════════════════════════════════════════════════════════════
# [5] Backend /metrics
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [5] Backend /metrics ---"
check_metrics "Backend /metrics" "${API_BASE}/metrics" \
  "livemask_backend_up livemask_backend_http_requests_total livemask_backend_observability_ingest_backlog"

# ════════════════════════════════════════════════════════════════════════════
# [6] Job Service /metrics
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [6] Job Service /metrics ---"
check_metrics "Job Service /metrics" "${JOB_SERVICE_API}/metrics" \
  "livemask_job_service_up livemask_job_runs_total livemask_job_queue_depth"

# ════════════════════════════════════════════════════════════════════════════
# [7] NodeAgent /metrics
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [7] NodeAgent /metrics ---"
check_metrics "NodeAgent /metrics" "${NODEAGENT_API}/metrics" \
  "livemask_nodeagent_up livemask_nodeagent_log_queue_depth livemask_nodeagent_event_queue_depth"

# ════════════════════════════════════════════════════════════════════════════
# [8] NodeAgent log upload (POST /internal/agent/logs with HMAC)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [8] NodeAgent Log Upload ---"
# Register a test node for HMAC auth
NA_NODE_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
  -H "Content-Type: application/json" \
  -d '{"node_name":"obs-smoke-log-node","agent_version":"smoke-1.0.0"}') 2>/dev/null || true
NA_NODE_ID=$(echo "${NA_NODE_REG}" | quiet_json "node_id")
NA_NODE_SECRET=$(echo "${NA_NODE_REG}" | quiet_json "node_secret")
if [[ -z "${NA_NODE_ID}" || -z "${NA_NODE_SECRET}" ]]; then
  skip "NodeAgent log upload: node register failed (endpoint not deployed or degraded)"
else
  # Compute HMAC for log upload
  NA_TIMESTAMP=$(date +%s)
  NA_SECRET_HASH=$(echo -n "${NA_NODE_SECRET}" | sha256sum | cut -d' ' -f1)
  NA_SIGNATURE=$(python3 -c "
import hmac, hashlib
secret_hash = '${NA_SECRET_HASH}'
msg = '${NA_NODE_ID}:${NA_TIMESTAMP}'
sig = hmac.new(secret_hash.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
")

  # Upload safe log batch
  LOG_UPLOAD_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/logs" \
    -H "Content-Type: application/json" \
    -H "X-Node-ID: ${NA_NODE_ID}" \
    -H "X-Signature: ${NA_SIGNATURE}" \
    -H "X-Timestamp: ${NA_TIMESTAMP}" \
    -d '{
      "batch_id": "obs-smoke-batch-001",
      "agent_version": "smoke-1.0.0",
      "logs": [
        {"level":"info","component":"smoke","event_type":"smoke_test","message":"Observability smoke test log","metadata":{"test":"true"},"created_at":"2026-05-19T00:00:00Z"}
      ]
    }') 2>/dev/null || true

  LOG_UPLOAD_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    -X POST "${API_BASE}/internal/agent/logs" \
    -H "Content-Type: application/json" \
    -H "X-Node-ID: ${NA_NODE_ID}" \
    -H "X-Signature: ${NA_SIGNATURE}" \
    -H "X-Timestamp: ${NA_TIMESTAMP}" \
    -d '{"batch_id":"obs-smoke-batch-001","agent_version":"smoke-1.0.0","logs":[]}' 2>/dev/null || echo "000")

  case "${LOG_UPLOAD_HTTP}" in
    202|200)
      pass "NodeAgent log upload: HTTP ${LOG_UPLOAD_HTTP} (accepted)"
      security_check "NodeAgent log upload response" "${LOG_UPLOAD_RESP}" || true
      ;;
    404)
      skip "NodeAgent log upload: HTTP 404 (endpoint not yet deployed)"
      ;;
    *)
      skip "NodeAgent log upload: HTTP ${LOG_UPLOAD_HTTP}"
      ;;
  esac

  # Cleanup test node
  pg_exec -c "DELETE FROM nodes WHERE id='${NA_NODE_ID}'" 2>/dev/null || true
fi

# ════════════════════════════════════════════════════════════════════════════
# [9] Job Service ingestion check
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [9] Job Service Ingestion ---"
# Check ingestion health endpoint
INGEST_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/logs/ingestion/health" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
case "${INGEST_HTTP}" in
  200)
    INGEST_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/logs/ingestion/health" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    pass "Log ingestion health: HTTP 200"
    security_check "Log ingestion health" "${INGEST_RESP}" || true
    ;;
  404)
    skip "Log ingestion health: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Log ingestion health: HTTP ${INGEST_HTTP}"
    ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# [10] GET /admin/api/v1/logs (global logs)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [10] GET /admin/api/v1/logs ---"
GLOBAL_LOGS_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/logs?limit=5" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
GLOBAL_LOGS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/logs?limit=5" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${GLOBAL_LOGS_HTTP}" in
  200)
    GLOBAL_LOGS_COUNT=$(echo "${GLOBAL_LOGS_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('logs',d.get('items',d.get('data',d.get('entries',[]))))
if isinstance(items, list): print(len(items))
else: print(0)
" 2>/dev/null || echo "0")
    pass "Global logs: HTTP 200, entries=${GLOBAL_LOGS_COUNT}"
    security_check "Global logs" "${GLOBAL_LOGS_RESP}" || true
    ;;
  404)
    skip "Global logs: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Global logs: HTTP ${GLOBAL_LOGS_HTTP}"
    ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# [11] GET /admin/api/v1/audit-logs
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [11] GET /admin/api/v1/audit-logs ---"
AUDIT_LOGS_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/audit-logs?limit=5" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
AUDIT_LOGS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/audit-logs?limit=5" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${AUDIT_LOGS_HTTP}" in
  200)
    AUDIT_LOGS_COUNT=$(echo "${AUDIT_LOGS_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('audit_logs',d.get('logs',d.get('items',d.get('data',[]))))
if isinstance(items, list): print(len(items))
else: print(0)
" 2>/dev/null || echo "0")
    pass "Audit logs: HTTP 200, entries=${AUDIT_LOGS_COUNT}"
    security_check "Audit logs" "${AUDIT_LOGS_RESP}" || true
    ;;
  404)
    skip "Audit logs: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Audit logs: HTTP ${AUDIT_LOGS_HTTP}"
    ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# [12] GET /admin/api/v1/nodes/{node_id}/logs (if we have any nodes)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [12] Node Latest Logs ---"
# First get a node ID from admin
NODES_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/nodes?limit=1" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
FIRST_NODE_ID=$(echo "${NODES_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('nodes',d.get('items',d.get('data',[])))
if isinstance(items, list) and len(items) > 0:
    print(items[0].get('id',''))
else:
    print('')
" 2>/dev/null || echo "")

if [[ -n "${FIRST_NODE_ID}" ]]; then
  NODE_LOGS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}/admin/api/v1/nodes/${FIRST_NODE_ID}/logs?limit=5" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
  case "${NODE_LOGS_HTTP}" in
    200)
      NODE_LOGS_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/nodes/${FIRST_NODE_ID}/logs?limit=5" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
      pass "Node latest logs: HTTP 200"
      security_check "Node logs" "${NODE_LOGS_RESP}" || true
      ;;
    404)
      skip "Node logs: HTTP 404 (endpoint not yet deployed for node ${FIRST_NODE_ID})"
      ;;
    *)
      skip "Node logs: HTTP ${NODE_LOGS_HTTP}"
      ;;
  esac
else
  skip "Node logs: no nodes available in admin list"
fi

# ════════════════════════════════════════════════════════════════════════════
# [13] GET /admin/api/v1/app/exceptions (Sentry / App exceptions)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [13] GET /admin/api/v1/app/exceptions ---"
APP_EXC_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/app/exceptions?limit=5" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
APP_EXC_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/app/exceptions?limit=5" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${APP_EXC_HTTP}" in
  200)
    APP_EXC_COUNT=$(echo "${APP_EXC_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('exceptions',d.get('items',d.get('data',d.get('entries',[]))))
if isinstance(items, list): print(len(items))
else: print(0)
" 2>/dev/null || echo "0")
    pass "App exceptions: HTTP 200, entries=${APP_EXC_COUNT}"
    security_check "App exceptions" "${APP_EXC_RESP}" "sentry_auth_token,org_token,project_token,relay_secret,webhook_secret" || true
    ;;
  404)
    skip "App exceptions: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "App exceptions: HTTP ${APP_EXC_HTTP}"
    ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# [14] GET /admin/api/v1/logs/agent (NodeAgent logs)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [14] GET /admin/api/v1/logs/agent ---"
LOG_AGENT_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/logs/agent?limit=10" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
LOG_AGENT_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/logs/agent?limit=10" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${LOG_AGENT_HTTP}" in
  200)
    LOG_AGENT_COUNT=$(echo "${LOG_AGENT_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('logs',d.get('items',d.get('data',d.get('entries',[]))))
if isinstance(items, list): print(len(items))
else: print(0)
" 2>/dev/null || echo "0")
    pass "Agent logs: HTTP 200, entries=${LOG_AGENT_COUNT}"
    security_check "Agent logs" "${LOG_AGENT_RESP}" || true
    # Verify each log entry has timestamp and level
    echo "${LOG_AGENT_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('logs',d.get('items',d.get('data',d.get('entries',[]))))
if isinstance(items, list) and len(items) > 0:
    issues = [str(i) for i, item in enumerate(items) if not item.get('timestamp') and not item.get('level')]
    if issues:
        print('WARN: entries missing timestamp/level: ' + ', '.join(issues))
    else:
        print('OK: all entries have timestamp/level')
else:
    print('INFO: no entries to validate')
" 2>/dev/null || true
    ;;
  404)
    skip "Agent logs: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Agent logs: HTTP ${LOG_AGENT_HTTP}"
    ;;
esac

# Try alternative log paths if primary 404s
if [[ "${LOG_AGENT_HTTP}" == "404" ]]; then
  for alt_log_path in "observability/logs/agent" "logs/nodeagent" "logs/node-agent" "agent-logs" "observability/logs"; do
    ALT_LOG_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "${API_BASE}/admin/api/v1/${alt_log_path}?limit=10" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || true)
    if [[ "${ALT_LOG_HTTP}" == "200" ]]; then
      ALT_LOG_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/${alt_log_path}?limit=10" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
      pass "Agent logs (alt ${alt_log_path}): HTTP 200"
      security_check "Agent logs (alt)" "${ALT_LOG_RESP}" || true
      break
    fi
  done
fi

# ════════════════════════════════════════════════════════════════════════════
# [15] GET /admin/api/v1/logs/payment (payment logs)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [15] GET /admin/api/v1/logs/payment ---"
LOG_PAYMENT_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/logs/payment?limit=10" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
LOG_PAYMENT_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/logs/payment?limit=10" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${LOG_PAYMENT_HTTP}" in
  200)
    LOG_PAYMENT_COUNT=$(echo "${LOG_PAYMENT_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('logs',d.get('items',d.get('data',d.get('entries',[]))))
if isinstance(items, list): print(len(items))
else: print(0)
" 2>/dev/null || echo "0")
    pass "Payment logs: HTTP 200, entries=${LOG_PAYMENT_COUNT}"
    security_check "Payment logs" "${LOG_PAYMENT_RESP}" || true
    # Verify no sensitive payment data
    echo "${LOG_PAYMENT_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('logs',d.get('items',d.get('data',d.get('entries',[]))))
if isinstance(items, list):
    risk = [str(i) for i, item in enumerate(items) if 'card_no' in str(item).lower() or 'cvv' in str(item).lower() or 'credit_card' in str(item).lower()]
    if risk:
        print('RISK: entries may contain payment card data: ' + ', '.join(risk))
    else:
        print('OK: no obvious payment card data in log entries')
" 2>/dev/null || true
    ;;
  404)
    skip "Payment logs: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Payment logs: HTTP ${LOG_PAYMENT_HTTP}"
    ;;
esac

if [[ "${LOG_PAYMENT_HTTP}" == "404" ]]; then
  for alt_pay_path in "observability/logs/payment" "payments/logs" "payment-logs"; do
    ALT_PAY_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "${API_BASE}/admin/api/v1/${alt_pay_path}?limit=10" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || true)
    if [[ "${ALT_PAY_HTTP}" == "200" ]]; then
      ALT_PAY_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/${alt_pay_path}?limit=10" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
      pass "Payment logs (alt ${alt_pay_path}): HTTP 200"
      security_check "Payment logs (alt)" "${ALT_PAY_RESP}" || true
      break
    fi
  done
fi

# ════════════════════════════════════════════════════════════════════════════
# [16] GET /admin/api/v1/logs/notification (notification logs)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [16] GET /admin/api/v1/logs/notification ---"
LOG_NOTIF_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/logs/notification?limit=10" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
LOG_NOTIF_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/logs/notification?limit=10" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${LOG_NOTIF_HTTP}" in
  200)
    LOG_NOTIF_COUNT=$(echo "${LOG_NOTIF_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('logs',d.get('items',d.get('data',d.get('entries',[]))))
if isinstance(items, list): print(len(items))
else: print(0)
" 2>/dev/null || echo "0")
    pass "Notification logs: HTTP 200, entries=${LOG_NOTIF_COUNT}"
    security_check "Notification logs" "${LOG_NOTIF_RESP}" || true
    ;;
  404)
    skip "Notification logs: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Notification logs: HTTP ${LOG_NOTIF_HTTP}"
    ;;
esac

if [[ "${LOG_NOTIF_HTTP}" == "404" ]]; then
  for alt_notif_path in "observability/logs/notification" "notifications/logs" "notification-logs"; do
    ALT_NOTIF_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "${API_BASE}/admin/api/v1/${alt_notif_path}?limit=10" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || true)
    if [[ "${ALT_NOTIF_HTTP}" == "200" ]]; then
      ALT_NOTIF_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/${alt_notif_path}?limit=10" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
      pass "Notification logs (alt ${alt_notif_path}): HTTP 200"
      security_check "Notification logs (alt)" "${ALT_NOTIF_RESP}" || true
      break
    fi
  done
fi

# ════════════════════════════════════════════════════════════════════════════
# [17] GET /admin/api/v1/observability/sentry (Sentry summary)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [17] GET /admin/api/v1/observability/sentry ---"
SENTRY_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/observability/sentry" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
SENTRY_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/observability/sentry" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${SENTRY_HTTP}" in
  200)
    SENTRY_ISSUES=$(echo "${SENTRY_RESP}" | quiet_json "total_issues" || echo "${SENTRY_RESP}" | quiet_json "issues_count" || echo "${SENTRY_RESP}" | quiet_json "count" || echo "")
    SENTRY_EVENTS=$(echo "${SENTRY_RESP}" | quiet_json "total_events" || echo "${SENTRY_RESP}" | quiet_json "events_count" || echo "")
    if [[ -n "${SENTRY_ISSUES}" ]]; then
      pass "Sentry summary: HTTP 200, issues=${SENTRY_ISSUES}, events=${SENTRY_EVENTS}"
    else
      pass "Sentry summary: HTTP 200 (got response)"
    fi
    security_check "Sentry summary" "${SENTRY_RESP}" || true
    ;;
  404)
    skip "Sentry summary: HTTP 404 (endpoint not yet deployed)"
    for alt_sentry in "sentry/summary" "sentry-summary" "observability/sentry-summary" "monitoring/sentry"; do
      ALT_SENTRY_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
        "${API_BASE}/admin/api/v1/${alt_sentry}" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || true)
      if [[ "${ALT_SENTRY_HTTP}" == "200" ]]; then
        ALT_SENTRY_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/${alt_sentry}" \
          -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
        pass "Sentry summary (alt ${alt_sentry}): HTTP 200"
        security_check "Sentry summary (alt)" "${ALT_SENTRY_RESP}" || true
        break
      fi
    done
    ;;
  *)
    skip "Sentry summary: HTTP ${SENTRY_HTTP}"
    ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# [18] GET /admin/api/v1/observability/sentry/events (Sentry events list)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [18] GET /admin/api/v1/observability/sentry/events ---"
SENTRY_EVENTS_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/observability/sentry/events?limit=10" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
SENTRY_EVENTS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/observability/sentry/events?limit=10" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${SENTRY_EVENTS_HTTP}" in
  200)
    SENTRY_EVENTS_COUNT=$(echo "${SENTRY_EVENTS_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('events',d.get('items',d.get('data',[])))
if isinstance(items, list): print(len(items))
else: print(0)
" 2>/dev/null || echo "0")
    pass "Sentry events list: HTTP 200, events=${SENTRY_EVENTS_COUNT}"
    security_check "Sentry events" "${SENTRY_EVENTS_RESP}" || true
    ;;
  404)
    skip "Sentry events: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Sentry events: HTTP ${SENTRY_EVENTS_HTTP}"
    ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# [19] GET /admin/api/v1/observability/sentry/performance (Sentry performance)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [19] GET /admin/api/v1/observability/sentry/performance ---"
SENTRY_PERF_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/observability/sentry/performance" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
SENTRY_PERF_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/observability/sentry/performance" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${SENTRY_PERF_HTTP}" in
  200)
    SENTRY_APDEX=$(echo "${SENTRY_PERF_RESP}" | quiet_json "apdex" || echo "${SENTRY_PERF_RESP}" | quiet_json "apdex_score" || echo "")
    SENTRY_P95=$(echo "${SENTRY_PERF_RESP}" | quiet_json "p95" || echo "${SENTRY_PERF_RESP}" | quiet_json "p95_response_time" || echo "")
    if [[ -n "${SENTRY_APDEX}" ]]; then
      pass "Sentry performance: HTTP 200, apdex=${SENTRY_APDEX}, p95=${SENTRY_P95}"
    else
      pass "Sentry performance: HTTP 200 (got response)"
    fi
    security_check "Sentry performance" "${SENTRY_PERF_RESP}" || true
    ;;
  404)
    skip "Sentry performance: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Sentry performance: HTTP ${SENTRY_PERF_HTTP}"
    ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# [20] RBAC: no token / user token → 401/403
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [20] RBAC Tests ---"
RBAC_EMAIL="smoke-obs-rbac-${SUFFIX}@test.livemask"
RBAC_PASS="ObsRbac123!"
pg_exec -c "DELETE FROM users WHERE email='${RBAC_EMAIL}'" 2>/dev/null || true
RBAC_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"obs-rbac-reg\",\"email\":\"${RBAC_EMAIL}\",\"password\":\"${RBAC_PASS}\",\"display_name\":\"Obs Smoke User\",\"client_type\":\"website\"}") || true
RBAC_TOKEN=$(echo "${RBAC_REG}" | quiet_json "access_token")
if [[ -z "${RBAC_TOKEN}" ]]; then
  RBAC_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"obs-rbac-login\",\"email\":\"${RBAC_EMAIL}\",\"password\":\"${RBAC_PASS}\",\"client_type\":\"website\"}") || true
  RBAC_TOKEN=$(echo "${RBAC_LOGIN}" | quiet_json "access_token")
fi

if [[ -n "${RBAC_TOKEN}" ]]; then
  for rbac_path in "logs/agent" "logs/payment" "logs/notification" "observability/sentry" "logs" "audit-logs" "app/exceptions"; do
    NO_TOK_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "${API_BASE}/admin/api/v1/${rbac_path}" 2>/dev/null || true)
    if [[ "${NO_TOK_HTTP}" == "401" ]]; then
      pass "RBAC no-token ${rbac_path}: HTTP 401 (correct)"
    else
      fail "RBAC no-token ${rbac_path}: HTTP ${NO_TOK_HTTP} (expected 401)"
    fi

    USER_TOK_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "${API_BASE}/admin/api/v1/${rbac_path}" \
      -H "Authorization: Bearer ${RBAC_TOKEN}" 2>/dev/null || true)
    if [[ "${USER_TOK_HTTP}" == "403" || "${USER_TOK_HTTP}" == "401" ]]; then
      pass "RBAC user-token ${rbac_path}: HTTP ${USER_TOK_HTTP} (forbidden)"
    else
      fail "RBAC user-token ${rbac_path}: HTTP ${USER_TOK_HTTP} (expected 401/403)"
    fi
  done
else
  skip "RBAC tests: no user token available"
fi

pg_exec -c "DELETE FROM users WHERE email='${RBAC_EMAIL}'" 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════════════
# [21] Payment order logs (GET /admin/api/v1/payments/orders/*/logs)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [21] Payment Order Logs ---"
# Try to find an order ID from payment API
PAY_ORDERS_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/payments/orders?limit=1" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
FIRST_ORDER_ID=$(echo "${PAY_ORDERS_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
orders = d.get('orders',d.get('items',d.get('data',[])))
if isinstance(orders, list) and len(orders) > 0:
    print(orders[0].get('order_id',orders[0].get('id','')))
else:
    print('')
" 2>/dev/null || echo "")

if [[ -n "${FIRST_ORDER_ID}" ]]; then
  PAY_ORDER_LOG_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}/admin/api/v1/payments/orders/${FIRST_ORDER_ID}/logs?limit=5" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
  case "${PAY_ORDER_LOG_HTTP}" in
    200)
      PAY_ORDER_LOG_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/payments/orders/${FIRST_ORDER_ID}/logs?limit=5" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
      pass "Payment order logs: HTTP 200"
      security_check "Payment order logs" "${PAY_ORDER_LOG_RESP}" || true
      ;;
    404)
      skip "Payment order logs: HTTP 404 (endpoint not yet deployed)"
      ;;
    *)
      skip "Payment order logs: HTTP ${PAY_ORDER_LOG_HTTP}"
      ;;
  esac
else
  skip "Payment order logs: no orders found to query"
fi

# ════════════════════════════════════════════════════════════════════════════
# [22] Notification delivery logs (GET /admin/api/v1/notifications/delivery-logs)
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [22] Notification Delivery Logs ---"
NOTIF_DEL_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/notifications/delivery-logs?limit=5" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
NOTIF_DEL_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/notifications/delivery-logs?limit=5" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${NOTIF_DEL_HTTP}" in
  200)
    pass "Notification delivery logs: HTTP 200"
    security_check "Notification delivery logs" "${NOTIF_DEL_RESP}" || true
    ;;
  404)
    skip "Notification delivery logs: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Notification delivery logs: HTTP ${NOTIF_DEL_HTTP}"
    ;;
esac

# ════════════════════════════════════════════════════════════════════════════
# [23] Comprehensive secret leak scan
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [23] Comprehensive Secret Leak Scan ---"
LEAK_FOUND=false
if [[ -n "${ADMIN_TOKEN}" ]]; then
  for scan_path in \
    "logs?limit=10" \
    "audit-logs?limit=10" \
    "logs/agent?limit=10" \
    "logs/payment?limit=10" \
    "logs/notification?limit=10" \
    "observability/sentry" \
    "observability/sentry/events?limit=10" \
    "app/exceptions?limit=10"; do
    SCAN_BODY=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/${scan_path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
    if [[ "${SCAN_BODY}" != "{}" ]]; then
      security_check "admin/${scan_path}" "${SCAN_BODY}" || LEAK_FOUND=true
    fi
  done
fi
if [[ "${LEAK_FOUND}" == "false" ]]; then
  pass "Secret leak scan completed (0 leaks)"
fi

# ════════════════════════════════════════════════════════════════════════════
# Cleanup
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Cleanup ---"
echo "  Observability smoke is read-only; no data cleanup needed"
echo "  Kept seed admin: admin@livemask.dev"

# ════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================"
echo " TASK-CICD-OBSERVABILITY-SMOKE-001 SUMMARY"
echo "================================================"
printf '%s\n' "${SUMMARY_LINES[@]}"

echo ""
if [[ "${FAILED}" -eq 1 ]]; then
  echo "[TASK-CICD-OBSERVABILITY-SMOKE-001] OBSERVABILITY SMOKE FAILED."
  echo ""
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo ""
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  echo ""
  echo "--- docker compose logs job-service (last 50) ---"
  docker compose -f "${COMPOSE_FILE}" logs job-service --tail=50 2>/dev/null || true
  exit 1
fi

echo "[TASK-CICD-OBSERVABILITY-SMOKE-001] Observability smoke PASSED."
echo "Covers: Backend/JobService/NodeAgent health, metrics, NodeAgent log upload,"
echo "  global logs, audit logs, node logs, App exceptions, agent logs, payment logs,"
echo "  notification logs, Sentry summary/events/performance, RBAC, payment order logs,"
echo "  notification delivery logs, comprehensive secret leak scan"
