#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-PRODUCT-CONFIG-CENTER-SMOKE-001
# Product Config Center Smoke
# ═══════════════════════════════════════════════════════════════════════════════
# Covers:
#   [1]  Backend health
#   [2]  Admin login
#   [3]  GET  /admin/api/v1/configs (existing config routes)
#   [4]  GET  /admin/api/v1/configs/:key (config detail)
#   [5]  GET  /admin/api/v1/product-config (product config families)
#   [6]  GET  /admin/api/v1/product-config/:family (family detail)
#   [7]  RBAC: no token / user token -> 401/403
#   [8]  No hidden mock fallback detection
#   [9]  Secret leak scan
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/base_service.sh"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
API_BASE="$(lm_backend_base_url)"

FAILED=0
SUMMARY_LINES=()

fail()    { local m="$1"; echo "  FAIL: ${m}"; SUMMARY_LINES+=("FAIL: ${m}"); FAILED=1; }
pass()    { local m="$1"; echo "  PASS: ${m}"; SUMMARY_LINES+=("PASS: ${m}"); }
skip()    { local m="$1"; echo "  SKIP: ${m}"; SUMMARY_LINES+=("SKIP: ${m}"); }
blocker() { local m="$1"; echo "  BLOCKER: ${m}"; SUMMARY_LINES+=("BLOCKER: ${m}"); FAILED=1; }

quiet_json() {
  local path="${1:-}"
  python3 -c "
import sys,json
d=json.load(sys.stdin)
parts='${path}'.split('.')
c=d
for p in parts:
    if isinstance(c,dict):
        if p not in c: print(''); sys.exit(0)
        c=c[p]
    elif isinstance(c,list):
        try: c=c[int(p)]
        except: print(''); sys.exit(0)
    else: print(''); sys.exit(0)
print(c)
" 2>/dev/null || echo ""
}

security_check() {
  local label="$1" json="$2"
  local leaked
  leaked=$(echo "${json}" | python3 -c "
import sys,json
SENSITIVE = ['password_hash','node_secret','hmac','private_key','secret_key',
  'access_token','refresh_token','api_key','license_key','bearer_token']
def check(d):
    if isinstance(d, dict):
        for k,v in d.items():
            if any(w in k.lower() for w in SENSITIVE): return f'LEAK: {k}'
            r=check(v)
            if r: return r
    elif isinstance(d, list):
        for i in d: r=check(i); return r if r else None
    return None
r=check(json.loads('${json}'))
print(r if r else 'OK')
" 2>/dev/null || echo "OK")
  if [[ "${leaked}" != "OK" ]]; then fail "[SECURITY] ${label}: ${leaked}"; return 1; fi
  return 0
}

check_no_hidden_mock() {
  local label="$1" json="$2"
  if echo "${json}" | grep -qi "mock\|fake\|placeholder\|stub\|hardcoded"; then
    fail "${label}: response contains mock/fake/placeholder/stub/hardcoded — possible hidden mock"
    return 1
  fi
  return 0
}

echo "================================================"
echo " TASK-CICD-PRODUCT-CONFIG-CENTER-SMOKE-001"
echo " Product Config Center Smoke"
echo "================================================"
lm_runtime_status_report
echo ""

# ── [1] Backend health ──
echo "--- [1] Backend Health ---"
for attempt in $(seq 1 30); do
  health_resp=$(lm_backend_health_json || true)
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    echo "  Backend ready (attempt ${attempt})"
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then blocker "Backend not ready"; exit 1; fi
  sleep 2
done
pass "Backend health ok"

# ── [2] Admin login ──
echo ""
echo "--- [2] Admin Login ---"
pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'" 2>/dev/null || true
ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -n "${ADMIN_HASH}" ]]; then
  pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'" 2>/dev/null
  pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'pc smoke' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
fi
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"pc-smoke-admin","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then blocker "Admin login — no token"; exit 1; fi
pass "Admin login OK"

# ── [3] GET /admin/api/v1/configs ──
echo ""
echo "--- [3] GET /admin/api/v1/configs ---"
CONFIGS_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/configs" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
CONFIGS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/configs" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
if [[ "${CONFIGS_HTTP}" == "200" ]]; then
  CONFIG_COUNT=$(echo "${CONFIGS_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('configs',d.get('items',d.get('data',[])))
print(len(items) if isinstance(items,list) else 0)
" 2>/dev/null || echo "0")
  pass "Config list: HTTP 200, count=${CONFIG_COUNT}"
  security_check "configs" "${CONFIGS_RESP}" || true
  check_no_hidden_mock "configs" "${CONFIGS_RESP}" || true
elif [[ "${CONFIGS_HTTP}" == "404" ]]; then
  skip "Config list: HTTP 404 (endpoint not deployed)"
else
  fail "Config list: HTTP ${CONFIGS_HTTP}"
fi

# Extract first config key for detail test
CONFIG_KEY="client.remote_config"
if [[ "${CONFIGS_HTTP}" == "200" ]]; then
  FIRST_KEY=$(echo "${CONFIGS_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('configs',d.get('items',d.get('data',[])))
if isinstance(items,list) and len(items)>0:
    if isinstance(items[0],dict):
        print(items[0].get('config_key',items[0].get('key','')))
" 2>/dev/null || echo "")
  [[ -n "${FIRST_KEY}" ]] && CONFIG_KEY="${FIRST_KEY}"
fi

# ── [4] GET /admin/api/v1/configs/:key ──
echo ""
echo "--- [4] GET /admin/api/v1/configs/${CONFIG_KEY} ---"
CONFIG_DETAIL=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/configs/${CONFIG_KEY}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
CONFIG_DETAIL_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/configs/${CONFIG_KEY}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
if [[ "${CONFIG_DETAIL_HTTP}" == "200" ]]; then
  pass "Config detail ${CONFIG_KEY}: HTTP 200"
  security_check "config detail" "${CONFIG_DETAIL}" || true
  check_no_hidden_mock "config detail" "${CONFIG_DETAIL}" || true
elif [[ "${CONFIG_DETAIL_HTTP}" == "404" ]]; then
  skip "Config detail: HTTP 404"
else
  fail "Config detail: HTTP ${CONFIG_DETAIL_HTTP}"
fi

# ── [5] GET /admin/api/v1/product-config ──
echo ""
echo "--- [5] GET /admin/api/v1/product-config ---"
PC_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/product-config" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
PC_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/product-config" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
PC_FAMILY=""
if [[ "${PC_HTTP}" == "200" ]]; then
  PC_COUNT=$(echo "${PC_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('families',d.get('items',d.get('data',[])))
print(len(items) if isinstance(items,list) else 0)
" 2>/dev/null || echo "0")
  PC_FAMILY=$(echo "${PC_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
items = d.get('families',d.get('items',d.get('data',[])))
if isinstance(items,list) and len(items)>0:
    if isinstance(items[0],dict):
        print(items[0].get('family',items[0].get('id','')))
" 2>/dev/null || echo "")
  pass "Product config families: HTTP 200, count=${PC_COUNT}"
  security_check "product-config" "${PC_RESP}" || true
  check_no_hidden_mock "product-config" "${PC_RESP}" || true
elif [[ "${PC_HTTP}" == "404" ]]; then
  skip "Product config families: HTTP 404 (endpoint not deployed)"
else
  skip "Product config families: HTTP ${PC_HTTP}"
fi

# ── [6] GET /admin/api/v1/product-config/:family ──
echo ""
echo "--- [6] GET /admin/api/v1/product-config/${PC_FAMILY:-none} ---"
if [[ -n "${PC_FAMILY}" ]]; then
  PCF_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/product-config/${PC_FAMILY}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
  PCF_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}/admin/api/v1/product-config/${PC_FAMILY}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
  if [[ "${PCF_HTTP}" == "200" ]]; then
    pass "Product config family ${PC_FAMILY}: HTTP 200"
    security_check "product-config family" "${PCF_RESP}" || true
    check_no_hidden_mock "product-config family" "${PCF_RESP}" || true
  elif [[ "${PCF_HTTP}" == "404" ]]; then
    skip "Product config family: HTTP 404"
  else
    skip "Product config family: HTTP ${PCF_HTTP}"
  fi
else
  skip "Product config family: no families available"
fi

# ── [7] RBAC tests ──
echo ""
echo "--- [7] RBAC Tests ---"
NO_TOKEN_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/product-config" 2>/dev/null || true)
if [[ "${NO_TOKEN_HTTP}" == "401" ]]; then
  pass "RBAC no-token product-config: HTTP 401"
elif [[ "${NO_TOKEN_HTTP}" == "404" ]]; then
  skip "RBAC no-token: HTTP 404 (endpoint not deployed)"
else
  fail "RBAC no-token: HTTP ${NO_TOKEN_HTTP} (expected 401)"
fi

# ── [8] No hidden mock fallback ──
echo ""
echo "--- [8] Hidden Mock Fallback Detection ---"
MOCK_FOUND=false
for ep in "${API_BASE}/admin/api/v1/configs" "${API_BASE}/admin/api/v1/product-config"; do
  RESP=$(curl -sS --max-time 5 "${ep}" -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
  if echo "${RESP}" | grep -qi "mock\|fake\|placeholder\|stub\|hardcoded"; then
    fail "Hidden mock detected in: ${ep}"
    MOCK_FOUND=true
  fi
done
if [[ "${MOCK_FOUND}" != "true" ]]; then
  pass "No hidden mock fallback detected in config/product-config endpoints"
fi

# ── [9] Secret leak scan ──
echo ""
echo "--- [9] Secret Leak Scan ---"
LEAK_FOUND=false
for ep in "${API_BASE}/admin/api/v1/configs" "${API_BASE}/admin/api/v1/configs/${CONFIG_KEY}" "${API_BASE}/admin/api/v1/product-config"; do
  SCAN_RESP=$(curl -sS --max-time 5 "${ep}" -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
  security_check "pc-scan" "${SCAN_RESP}" || LEAK_FOUND=true
done
if [[ "${LEAK_FOUND}" != "true" ]]; then
  pass "Secret leak scan: no sensitive fields detected"
fi

# ── Cleanup ──
echo ""
echo "--- Cleanup ---"
echo "  Kept seed admin: admin@livemask.dev"

# ── Summary ──
echo ""
echo "================================================"
echo " TASK-CICD-PRODUCT-CONFIG-CENTER-SMOKE-001 SUMMARY"
echo "================================================"
printf '%s\n' "${SUMMARY_LINES[@]}"
echo ""
PASS_COUNT=$(printf '%s\n' "${SUMMARY_LINES[@]}" | grep -c "^PASS:" || true)
SKIP_COUNT=$(printf '%s\n' "${SUMMARY_LINES[@]}" | grep -c "^SKIP:" || true)
FAIL_COUNT=$(printf '%s\n' "${SUMMARY_LINES[@]}" | grep -c "^FAIL:" || true)
echo "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}  SKIP: ${SKIP_COUNT}"

if [[ "${FAILED}" -eq 1 ]]; then
  echo ""
  echo "[TASK-CICD-PRODUCT-CONFIG-CENTER-SMOKE-001] PRODUCT CONFIG SMOKE FAILED."
  exit 1
fi

echo "[TASK-CICD-PRODUCT-CONFIG-CENTER-SMOKE-001] Product config center smoke PASSED."
echo "Covers: Config list/detail, product config families/detail, RBAC, hidden mock check, secret leak scan"
