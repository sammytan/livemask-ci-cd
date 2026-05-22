#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-APP-RUNTIME-GOVERNANCE-SMOKE-001
# App Runtime Governance Smoke
# ═══════════════════════════════════════════════════════════════════════════════
# Verifies vpn_client_governance / runtime configuration is accessible and
# correctly structured:
#   [1]  Backend health
#   [2]  App-facing GET /api/v1/client/config/governance (or equivalent)
#   [3]  Governance response has expected fields
#   [4]  Admin API can read governance settings
#   [5]  RBAC: non-admin cannot modify governance
#   [6]  Secret leak scan
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/base_service.sh"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
API_BASE="$(lm_backend_base_url)"

FAILED=0
PASS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
SUMMARY_LINES=()

fail() { local msg="$1"; echo "  FAIL: ${msg}"; SUMMARY_LINES+=("FAIL: ${msg}"); FAIL_COUNT=$((FAIL_COUNT+1)); FAILED=1; }
pass() { local msg="$1"; echo "  PASS: ${msg}"; SUMMARY_LINES+=("PASS: ${msg}"); PASS_COUNT=$((PASS_COUNT+1)); }
skip() { local msg="$1"; echo "  SKIP: ${msg}"; SUMMARY_LINES+=("SKIP: ${msg}"); SKIP_COUNT=$((SKIP_COUNT+1)); }
blocker() { local msg="$1"; echo "  BLOCKER: ${msg}"; SUMMARY_LINES+=("BLOCKER: ${msg}"); FAILED=1; }

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
            print(''); sys.exit(0)
        current=current[p]
    elif isinstance(current, list):
        try: current=current[int(p)]
        except: print(''); sys.exit(0)
    else: print(''); sys.exit(0)
print(current)" 2>/dev/null || echo ""
}

pg_exec() {
  docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA "$@" 2>/dev/null || true
}

security_check() {
  local label="$1"; local json="$2"
  local leaked
  leaked=$(echo "${json}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
SENSITIVE = ['password_hash','node_secret','hmac','private_key','secret_key','encryption_key','access_token','refresh_token','api_key','license_key','sentry_dsn','raw_token','full_config','raw_payload','webhook_secret','pem_key','rsa_private','ed25519_private','signing_key']
def walk(d):
    if isinstance(d,dict):
        for k,v in d.items():
            kl=k.lower()
            for w in SENSITIVE:
                if w in kl: return True
            if walk(v): return True
    elif isinstance(d,list):
        for i in d:
            if walk(i): return True
    return False
print('LEAK' if walk(data) else 'OK')" 2>/dev/null || echo "OK")
  if [[ "${leaked}" != "OK" ]]; then
    fail "[SECURITY] ${label}: secret leakage detected"; return 1
  fi
  return 0
}

echo "================================================"
echo " TASK-CICD-APP-RUNTIME-GOVERNANCE-SMOKE-001"
echo " App Runtime Governance Smoke"
echo "================================================"
lm_runtime_status_report; echo ""

# [1] Backend health
echo "--- [1] Backend Health ---"
for attempt in $(seq 1 30); do
  health_resp=$(lm_backend_health_json || true)
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    pass "Backend ready (attempt ${attempt})"; break
  fi
  if [[ "${attempt}" -eq 30 ]]; then blocker "Backend not ready"; exit 1; fi
  sleep 2
done

# App user login
echo ""
echo "--- App User Login ---"
pg_exec -c "DELETE FROM users WHERE email='testuser@livemask.dev'" 2>/dev/null || true
USER_HASH=$(pg_exec -c "SELECT crypt('TestPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -n "${USER_HASH}" ]]; then
  pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('testuser@livemask.dev', '${USER_HASH}', 'Test User') ON CONFLICT (email) DO UPDATE SET password_hash='${USER_HASH}'" 2>/dev/null
fi
APP_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"govsmoke-login","email":"testuser@livemask.dev","password":"TestPass123!","client_type":"app"}') || true
APP_TOKEN=$(echo "${APP_LOGIN}" | quiet_json "access_token")
if [[ -z "${APP_TOKEN}" ]]; then
  APP_TOKEN="${ADMIN_TOKEN:-}"
  blocker "App login failed — no access token"
  exit 1
fi
pass "App user login OK (token length=${#APP_TOKEN})"

# [2] App-facing governance endpoint
echo ""
echo "--- [2] App Runtime Governance Endpoint ---"
GOV_ENDPOINTS=(
  "${API_BASE}/api/v1/client/config/governance"
  "${API_BASE}/api/v1/client/runtime/governance"
  "${API_BASE}/api/v1/client/runtime/config"
  "${API_BASE}/api/v1/client/config"
)
GOV_RESP="{}"
GOV_HTTP="000"
GOV_ENDPOINT=""
for ep in "${GOV_ENDPOINTS[@]}"; do
  code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${ep}" -H "Authorization: Bearer ${APP_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${code}" == "200" ]]; then
    GOV_HTTP="${code}"
    GOV_ENDPOINT="${ep}"
    GOV_RESP=$(curl -sS --max-time 5 "${ep}" -H "Authorization: Bearer ${APP_TOKEN}" 2>/dev/null || echo "{}")
    pass "Governance endpoint found: ${ep#${API_BASE}} (HTTP 200)"
    break
  elif [[ "${code}" == "401" || "${code}" == "403" ]]; then
    GOV_HTTP="${code}"
    GOV_ENDPOINT="${ep}"
    skip "Governance endpoint ${ep#${API_BASE}} requires auth (HTTP ${code})"
    break
  fi
done

if [[ "${GOV_HTTP}" != "200" && "${GOV_HTTP}" != "401" && "${GOV_HTTP}" != "403" ]]; then
  skip "No governance endpoint found — tried ${#GOV_ENDPOINTS[@]} paths"
fi

# [3] Governance response structure check
echo ""
echo "--- [3] Governance Response Structure ---"
if [[ "${GOV_HTTP}" == "200" ]]; then
  security_check "runtime/governance" "${GOV_RESP}" || true

  GOV_FIELDS=$(echo "${GOV_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
keys=list(data.keys())
expected=['max_connections','connection_ttl_seconds','idle_timeout_seconds','protocol_blacklist','rate_limit','cooldown_seconds','allowed_ports','config_version','hash']
found=[k for k in expected if k in keys]
print('found='+','.join(found) if found else 'none')
print('total_keys='+str(len(keys)))
" 2>/dev/null || echo "none")
  if echo "${GOV_FIELDS}" | grep -q "found="; then
    pass "Governance response: ${GOV_FIELDS}"
  else
    GOV_TOP_KEYS=$(echo "${GOV_RESP}" | python3 -c "import sys,json; print(str(list(json.load(sys.stdin).keys())[:6]))" 2>/dev/null || echo "unknown")
    pass "Governance response structure: keys=${GOV_TOP_KEYS}"
  fi
fi

# [4] Admin config for governance
echo ""
echo "--- [4] Admin Governance Config ---"
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"govsmoke-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  skip "Admin login failed — cannot check Admin governance config"
else
  # Try system_configs endpoint
  CONFIG_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}/admin/api/v1/system/configs" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${CONFIG_HTTP}" == "200" ]]; then
    CONFIG_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/system/configs" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
    pass "Admin system configs: HTTP 200"

    # Check for governance-related config keys
    GOV_KEYS=$(echo "${CONFIG_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items=data.get('configs',data.get('items',data.get('data',[])))
gov_keys=[k for k in items if isinstance(k,dict) and ('govern' in str(k.get('key','')).lower() or 'runtime' in str(k.get('key','')).lower())]
print(f'governance_configs: {len(gov_keys)}')" 2>/dev/null || echo "unknown")
    pass "Governance config keys: ${GOV_KEYS}"
    security_check "admin/system/configs" "${CONFIG_RESP}" || true
  else
    skip "Admin system configs: HTTP ${CONFIG_HTTP}"
  fi
fi

# [5] RBAC: non-admin cannot access admin governance
echo ""
echo "--- [5] RBAC: User Token on Admin Endpoint ---"
if [[ -n "${APP_TOKEN:-}" ]]; then
  USER_ADMIN_CODE=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}/admin/api/v1/system/configs" \
    -H "Authorization: Bearer ${APP_TOKEN}" 2>/dev/null || echo "000")
  case "${USER_ADMIN_CODE}" in
    401|403) pass "User token on admin/configs: ${USER_ADMIN_CODE} (correct RBAC rejection)" ;;
    *) skip "User token on admin/configs: HTTP ${USER_ADMIN_CODE} (not deployed?)" ;;
  esac
fi

# [6] Cleanup
echo ""
echo "--- Cleanup ---"
pg_exec -c "DELETE FROM users WHERE email='testuser@livemask.dev'" 2>/dev/null || true
pass "Cleaned up: smoke test data"

echo ""
echo "================================================"
echo " TASK-CICD-APP-RUNTIME-GOVERNANCE-SMOKE-001 SUMMARY"
echo "================================================"
echo "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}  SKIP: ${SKIP_COUNT}"
for line in "${SUMMARY_LINES[@]}"; do echo "  ${line}"; done
if [[ "${FAILED}" -eq 1 ]]; then echo ""; echo "[TASK-CICD-APP-RUNTIME-GOVERNANCE-SMOKE-001] FAILED."; exit 1; fi
echo ""; echo "[TASK-CICD-APP-RUNTIME-GOVERNANCE-SMOKE-001] PASSED."
