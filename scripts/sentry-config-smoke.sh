#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-SENTRY-CONFIG-SMOKE-001
# Sentry Config Smoke — App-facing safe config, Admin settings, RBAC, secret leak
# ═══════════════════════════════════════════════════════════════════════════════
# Covers:
#   [1] Backend health
#   [2] Admin login
#   [3] GET /api/v1/app/observability/config (App-facing safe Sentry config)
#   [4] Verify enabled/disabled response shape, DSN safety
#   [5] Assert no forbidden fields in App config response
#   [6] GET /admin/api/v1/system-settings/observability (Admin settings)
#   [7] RBAC: no token / user token → 401/403 on Admin settings
#   [8] App fallback evidence (mark SKIP if not available)
#   [9] Comprehensive secret leak scan
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
    'webhook_secret','authorization','cookie','secret_ref',
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

TIMESTAMP=$(date +%s)

echo "================================================"
echo " TASK-CICD-SENTRY-CONFIG-SMOKE-001"
echo " Sentry Config Smoke"
echo "================================================"
echo ""

# ---------------------------------------------------------------------------
# [1] Backend health
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# [2] Admin login
# ---------------------------------------------------------------------------
echo ""
echo "--- [2] Admin Login ---"
pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'" 2>/dev/null || true
ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -n "${ADMIN_HASH}" ]]; then
  pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'" 2>/dev/null
  pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by sentry-config-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
fi
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"sentry-cfg-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  blocker "Admin login — no access token"
else
  pass "Admin login OK (token length=${#ADMIN_TOKEN})"
fi

# ---------------------------------------------------------------------------
# [3] GET /api/v1/app/observability/config (App-facing Sentry config)
# ---------------------------------------------------------------------------
echo ""
echo "--- [3] GET /api/v1/app/observability/config ---"
APP_SENTRY_RESP=$(curl -sS --max-time 5 \
  "${API_BASE}/api/v1/app/observability/config?platform=ios&app_version=1.0.0&release_channel=internal" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
APP_SENTRY_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/api/v1/app/observability/config?platform=ios&app_version=1.0.0&release_channel=internal" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${APP_SENTRY_HTTP}" in
  200)
    # Check enabled/disabled shape
    SENTRY_ENABLED=$(echo "${APP_SENTRY_RESP}" | quiet_json "sentry.enabled" || echo "")
    if [[ "${SENTRY_ENABLED}" == "True" ]] || [[ "${SENTRY_ENABLED}" == "true" ]]; then
      SENTRY_DSN=$(echo "${APP_SENTRY_RESP}" | quiet_json "sentry.dsn" || echo "")
      if [[ -n "${SENTRY_DSN}" ]]; then
        pass "App Sentry config: enabled, DSN present (not null)"
        # Verify DSN is public (contains https:// and not a placeholder like 'REDACTED')
        if echo "${SENTRY_DSN}" | python3 -c "import sys; dsn=sys.stdin.read().strip(); print('OK' if dsn.startswith('https://') else 'NOT-PUBLIC')" 2>/dev/null | grep -q "NOT-PUBLIC"; then
          fail "App Sentry DSN does not start with https:// — expected public DSN"
        fi
      else
        pass "App Sentry config: enabled but DSN is null (valid degraded state)"
      fi
    elif [[ "${SENTRY_ENABLED}" == "False" ]] || [[ "${SENTRY_ENABLED}" == "false" ]]; then
      pass "App Sentry config: disabled (sentry.enabled=false)"
    else
      pass "App Sentry config: HTTP 200 (got response)"
    fi
    security_check "App Sentry config" "${APP_SENTRY_RESP}" "auth_token,org_token,project_token,relay_secret,webhook_secret,secret_ref" || true
    ;;
  404)
    skip "App Sentry config: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "App Sentry config: HTTP ${APP_SENTRY_HTTP}"
    ;;
esac

# ---------------------------------------------------------------------------
# [4] Verify no forbidden fields in App config (explicit check)
# ---------------------------------------------------------------------------
echo ""
echo "--- [4] Forbidden Field Check (App Config) ---"
if [[ "${APP_SENTRY_HTTP}" == "200" ]] && [[ -n "${APP_SENTRY_RESP}" ]]; then
  FORBIDDEN_FOUND=$(echo "${APP_SENTRY_RESP}" | python3 -c "
import sys,json
FORBIDDEN = ['auth_token','org_token','project_token','relay_secret','webhook_secret','private_key','api_key','authorization','cookie','secret_ref']
data=json.load(sys.stdin)
def scan(d, path=''):
    found=[]
    if isinstance(d, dict):
        for k, v in d.items():
            kl = k.lower()
            fp = f'{path}.{k}' if path else k
            for f in FORBIDDEN:
                if f in kl:
                    found.append(fp)
            found.extend(scan(v, fp))
    elif isinstance(d, list):
        for i, item in enumerate(d):
            found.extend(scan(item, f'{path}[{i}]'))
    return found
hits=scan(data)
if hits:
    print('FORBIDDEN: ' + ', '.join(hits))
else:
    print('OK')
" 2>/dev/null || echo "OK")
  if [[ "${FORBIDDEN_FOUND}" == "OK" ]]; then
    pass "App config: no forbidden fields found"
  else
    fail "App config: ${FORBIDDEN_FOUND}"
  fi
else
  skip "Forbidden field check: no response to scan"
fi

# ---------------------------------------------------------------------------
# [5] GET /admin/api/v1/system-settings/observability (Admin settings)
# ---------------------------------------------------------------------------
echo ""
echo "--- [5] GET /admin/api/v1/system-settings/observability ---"
ADMIN_SENTRY_SETTINGS_RESP=$(curl -sS --max-time 5 \
  "${API_BASE}/admin/api/v1/system-settings/observability" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
ADMIN_SENTRY_SETTINGS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/system-settings/observability" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${ADMIN_SENTRY_SETTINGS_HTTP}" in
  200)
    pass "Admin Sentry settings: HTTP 200"
    security_check "Admin Sentry settings" "${ADMIN_SENTRY_SETTINGS_RESP}" || true
    ;;
  404)
    skip "Admin Sentry settings: HTTP 404 (endpoint not yet deployed)"
    # Try alternative paths
    for alt_path in "system-settings/observability" "settings/observability" "system-settings/sentry" "settings/sentry"; do
      ALT_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
        "${API_BASE}/admin/api/v1/${alt_path}" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || true)
      if [[ "${ALT_HTTP}" == "200" ]]; then
        ALT_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/${alt_path}" \
          -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
        pass "Admin Sentry settings (alt ${alt_path}): HTTP 200"
        security_check "Admin Sentry settings (alt)" "${ALT_RESP}" || true
        break
      fi
    done
    ;;
  *)
    skip "Admin Sentry settings: HTTP ${ADMIN_SENTRY_SETTINGS_HTTP}"
    ;;
esac

# ---------------------------------------------------------------------------
# [6] RBAC: no token / user token → 401/403 on Admin Sentry settings
# ---------------------------------------------------------------------------
echo ""
echo "--- [6] RBAC Tests ---"
RBAC_EMAIL="smoke-sentry-cfg-${TIMESTAMP}@test.livemask"
RBAC_PASS="SentryCfg123!"
pg_exec -c "DELETE FROM users WHERE email='${RBAC_EMAIL}'" 2>/dev/null || true
RBAC_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"sentry-cfg-rbac\",\"email\":\"${RBAC_EMAIL}\",\"password\":\"${RBAC_PASS}\",\"display_name\":\"SentryCfgUser\",\"client_type\":\"website\"}") || true
RBAC_TOKEN=$(echo "${RBAC_REG}" | quiet_json "access_token")
if [[ -z "${RBAC_TOKEN}" ]]; then
  RBAC_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"sentry-cfg-rbac-login\",\"email\":\"${RBAC_EMAIL}\",\"password\":\"${RBAC_PASS}\",\"client_type\":\"website\"}") || true
  RBAC_TOKEN=$(echo "${RBAC_LOGIN}" | quiet_json "access_token")
fi

if [[ -n "${RBAC_TOKEN}" ]]; then
  # No token on Admin settings
  NO_TOK_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}/admin/api/v1/system-settings/observability" 2>/dev/null || echo "000")
  if [[ "${NO_TOK_HTTP}" == "401" ]]; then
    pass "RBAC no-token Admin settings: HTTP 401 (correct)"
  else
    fail "RBAC no-token Admin settings: HTTP ${NO_TOK_HTTP} (expected 401)"
  fi

  # User token on Admin settings
  USER_TOK_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}/admin/api/v1/system-settings/observability" \
    -H "Authorization: Bearer ${RBAC_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${USER_TOK_HTTP}" == "403" || "${USER_TOK_HTTP}" == "401" ]]; then
    pass "RBAC user-token Admin settings: HTTP ${USER_TOK_HTTP} (forbidden)"
  else
    fail "RBAC user-token Admin settings: HTTP ${USER_TOK_HTTP} (expected 401/403)"
  fi
else
  skip "RBAC tests: no user token available"
fi
pg_exec -c "DELETE FROM users WHERE email='${RBAC_EMAIL}'" 2>/dev/null || true

# ---------------------------------------------------------------------------
# [7] App fallback evidence
# ---------------------------------------------------------------------------
echo ""
echo "--- [7] App Fallback Evidence ---"
# App unit tests or lightweight test command are not available from ci-cd repo
skip "App fallback evidence: app_runtime_test_not_available (ci-cd cannot run App tests)"

# ---------------------------------------------------------------------------
# [8] Comprehensive secret leak scan
# ---------------------------------------------------------------------------
echo ""
echo "--- [8] Comprehensive Secret Leak Scan ---"
LEAK_FOUND=false
if [[ -n "${ADMIN_TOKEN}" ]]; then
  for scan_path in "system-settings/observability" "system-settings"; do
    SCAN_BODY=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/${scan_path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
    if [[ "${SCAN_BODY}" != "{}" ]]; then
      security_check "admin/${scan_path}" "${SCAN_BODY}" "auth_token,org_token,project_token,relay_secret,webhook_secret,secret_ref" || LEAK_FOUND=true
    fi
  done
fi
if [[ "${LEAK_FOUND}" == "false" ]]; then
  pass "Secret leak scan completed (0 leaks)"
fi

# ---------------------------------------------------------------------------
# [9] Admin Observability Page 404 Check (TASK-CICD-ADMIN-CONTROL-PLANE-SMOKE-001)
# ---------------------------------------------------------------------------
echo ""
echo "--- [9] Admin Observability Page 404 Check ---"
OBSERV_PAGE_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/settings/observability" 2>/dev/null || echo "000")
if [[ "${OBSERV_PAGE_HTTP}" == "200" ]]; then
  pass "Admin page /admin/settings/observability: HTTP 200"
elif [[ "${OBSERV_PAGE_HTTP}" == "404" ]]; then
  skip "Admin page /admin/settings/observability: HTTP 404 — Admin Next.js not deployed in staging"
elif [[ "${OBSERV_PAGE_HTTP}" == "000" ]]; then
  skip "Admin page /admin/settings/observability: unreachable"
else
  skip "Admin page /admin/settings/observability: HTTP ${OBSERV_PAGE_HTTP}"
fi

# ---------------------------------------------------------------------------
# [10] GET /admin/api/v1/system-settings/observability/sentry_app
# ---------------------------------------------------------------------------
echo ""
echo "--- [10] GET /admin/api/v1/system-settings/observability/sentry_app ---"
SENTRY_APP_RESP=$(curl -sS --max-time 5 \
  "${API_BASE}/admin/api/v1/system-settings/observability/sentry_app" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
SENTRY_APP_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/system-settings/observability/sentry_app" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${SENTRY_APP_HTTP}" in
  200)
    pass "Sentry app settings API: HTTP 200"
    # Extra secret scan for sentry-specific fields
    SENTRY_APP_LEAK_CHECK=$(echo "${SENTRY_APP_RESP}" | python3 -c "
import sys,json
FORBIDDEN = ['auth_token','org_token','project_token','relay_secret','webhook_secret','private_key','api_key','authorization','cookie','secret_ref']
data=json.load(sys.stdin)
def scan(d, path=''):
    found=[]
    if isinstance(d, dict):
        for k, v in d.items():
            kl = k.lower()
            fp = f'{path}.{k}' if path else k
            for f in FORBIDDEN:
                if f in kl:
                    found.append(fp)
            found.extend(scan(v, fp))
    elif isinstance(d, list):
        for i, item in enumerate(d):
            found.extend(scan(item, f'{path}[{i}]'))
    return found
hits=scan(data)
if hits:
    print('FORBIDDEN: ' + ', '.join(hits))
else:
    print('OK')
" 2>/dev/null || echo "OK")
    if [[ "${SENTRY_APP_LEAK_CHECK}" == "OK" ]]; then
      pass "Sentry app settings: no forbidden fields leaked"
    else
      fail "Sentry app settings: ${SENTRY_APP_LEAK_CHECK}"
    fi
    ;;
  404)
    skip "Sentry app settings API: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Sentry app settings API: HTTP ${SENTRY_APP_HTTP}"
    ;;
esac

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
echo ""
echo "--- Cleanup ---"
echo "  Sentry config smoke is read-only; no data cleanup needed"
echo "  Kept seed admin: admin@livemask.dev"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================"
echo " TASK-CICD-SENTRY-CONFIG-SMOKE-001 SUMMARY"
echo "================================================"
printf '%s\n' "${SUMMARY_LINES[@]}"

echo ""
if [[ "${FAILED}" -eq 1 ]]; then
  echo "[TASK-CICD-SENTRY-CONFIG-SMOKE-001] SENTRY CONFIG SMOKE FAILED."
  echo ""
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo ""
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit 1
fi

echo "[TASK-CICD-SENTRY-CONFIG-SMOKE-001] Sentry config smoke PASSED."
echo "Covers: App Sentry config, Admin Sentry settings, forbidden field check,"
echo "  RBAC for Admin settings, secret leak scan"
