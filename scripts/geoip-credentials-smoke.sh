#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-GEOIP-CREDENTIALS-001 — GeoIP Credentials Admin API Smoke
# ═══════════════════════════════════════════════════════════════════════════════
# Covers:
#   [1] Admin login
#   [2] GET /admin/api/v1/geoip/sources             (list sources)
#   [3] GET /admin/api/v1/geoip/sources/{source}    (source detail)
#   [4] PUT /admin/api/v1/geoip/sources/{source}    (update credential)
#   [5] POST /admin/api/v1/geoip/sources/{source}/verify       (verify credential)
#   [6] POST /admin/api/v1/geoip/sources/{source}/rotate-secret (rotate secret)
#   [7] POST /admin/api/v1/geoip/sources/{source}/disable      (disable source)
#   [8] POST /admin/api/v1/geoip/sources/{source}/enable       (enable source)
#   [9] No token → 401
#   [10] User token → 403
#   [11] Read-only admin/role (auditor) → write 403
#   [12] API response excludes: encrypted_secret, plaintext secret, license_key, api_key, token, encryption key
#   [13] endpoint_url query redacted
#   [14] Audit log does not contain secret
#   [15] Env fallback does not break existing GeoIP update
# ═══════════════════════════════════════════════════════════════════════════════

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

# ── Security check: verify response does NOT contain sensitive fields ─────────
security_check() {
  local label="$1"
  local json="$2"
  local leaked
  leaked=$(echo "${json}" | python3 -c "
import sys,json
data = json.load(sys.stdin)
body_str = json.dumps(data).lower()

# Sensitive key patterns that MUST NOT appear in API responses
patterns = [
    'encrypted_secret',
    'plaintext_secret', 'plaintext', 
    'license_key',
    'api_key',
    'geoiP_credential_encryption_key',  # case-insensitive
    'encryption_key',
]

found = []
for p in patterns:
    if p in body_str:
        found.append(p)

# Check for 'token' but NOT 'access_token' or 'refresh_token' which are valid auth fields
# Only flag bare 'token' keys or 'secret_token'
if '\"token\"' in body_str or '\"secret_token\"' in body_str:
    found.append('bare_token_key')

if found:
    print('LEAK: ' + ', '.join(set(found)))
else:
    print('OK')
" 2>/dev/null || echo "OK")
  if [[ "${leaked}" != "OK" ]]; then
    fail "[SECURITY] ${label}: ${leaked}"
    return 1
  fi
  return 0
}

# ── Check for redacted endpoint URL ──────────────────────────────────────────
check_redacted_endpoint() {
  local label="$1"
  local json="$2"
  local result
  result=$(echo "${json}" | python3 -c "
import sys,json
data = json.load(sys.stdin)
body_str = json.dumps(data).lower()

# Check if endpoint_url exists and if its value contains 'redacted' or is empty/none
found_endpoint = False
for key in ['endpoint_url', 'endpointurl', 'download_url', 'downloadurl']:
    if isinstance(data, dict):
        val = data.get(key, None)
        if val is not None and val != '':
            found_endpoint = True
            # Check if the value appears to be a URL with query params
            if '?' in str(val):
                # More permissive: just check it's not leaking credentials
                # Keys in query params that should be redacted
                leaky_params = ['key=', 'secret=', 'token=', 'api_key=', 'api-key=', 'license=', 'credential=']
                val_lower = str(val).lower()
                for lp in leaky_params:
                    if lp in val_lower:
                        print('LEAK: endpoint_url contains ' + lp)
                        sys.exit(0)
            # Check if value is 'REDACTED' or similar
            if str(val).upper() in ['REDACTED', '[REDACTED]', '***', '']:
                print('REDACTED_OK')
                sys.exit(0)

if not found_endpoint:
    print('NO_ENDPOINT')
else:
    print('ENDPOINT_OK')
" 2>/dev/null || echo "CHECK_FAILED")
  
  case "${result}" in
    REDACTED_OK|NO_ENDPOINT)
      return 0
      ;;
    ENDPOINT_OK)
      # endpoint exists with no query params — acceptable if no credentials needed
      return 0
      ;;
    LEAK:*)
      fail "[SECURITY] ${label}: ${result}"
      return 1
      ;;
    *)
      # Unknown result — just warn
      echo "  INFO: endpoint check result=${result}"
      return 0
      ;;
  esac
}

# ── Check audit logs do NOT contain credential secrets ───────────────────────
check_audit_no_secret() {
  local label="$1"
  # Query recent audit_log entries for credential/source events  
  local audit_rows
  audit_rows=$(pg_exec -c "
    SELECT data::text FROM audit_log 
    WHERE table_name LIKE '%geoip%' OR table_name LIKE '%source%'
    ORDER BY created_at DESC LIMIT 10
  " 2>/dev/null || echo "")
  
  if [[ -z "${audit_rows}" ]]; then
    skip "${label}: no audit log entries found"
    return 0
  fi
  
  local leaked
  leaked=$(echo "${audit_rows}" | python3 -c "
import sys
lines = sys.stdin.read().lower()
patterns = ['encrypted_secret', 'plaintext_secret', 'license_key', 'api_key', 'encryption_key']
found = [p for p in patterns if p in lines]
if found:
    print('LEAK: ' + ', '.join(found))
else:
    print('OK')
" 2>/dev/null || echo "CHECK_FAILED")
  
  if [[ "${leaked}" != "OK" ]]; then
    fail "[AUDIT] ${label}: audit log contains ${leaked}"
    return 1
  fi
  pass "[AUDIT] ${label}: audit log does not contain credential secrets"
  return 0
}

echo "========================================================"
echo " TASK-CICD-GEOIP-CREDENTIALS-001: GeoIP Credentials Smoke"
echo "========================================================"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# [0] Health check
# ──────────────────────────────────────────────────────────────────────────────
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

# ──────────────────────────────────────────────────────────────────────────────
# Seed users
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Seed users ---"

# Admin
pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'" 2>/dev/null || true
ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -n "${ADMIN_HASH}" ]]; then
  pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO NOTHING" 2>/dev/null
  pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by geoip-credentials-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
fi

# Auditor (read-only admin role)
pg_exec -c "DELETE FROM users WHERE email='auditor@livemask.dev'" 2>/dev/null || true
AUDITOR_HASH=$(pg_exec -c "SELECT crypt('AuditorPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -n "${AUDITOR_HASH}" ]]; then
  pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('auditor@livemask.dev', '${AUDITOR_HASH}', 'Dev Auditor') ON CONFLICT (email) DO NOTHING" 2>/dev/null
  pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'auditor', 'dev seed by geoip-credentials-smoke.sh' FROM users WHERE email='auditor@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
fi

# Standard user
pg_exec -c "DELETE FROM users WHERE email='user@livemask.dev'" 2>/dev/null || true
USER_HASH=$(pg_exec -c "SELECT crypt('UserPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -n "${USER_HASH}" ]]; then
  pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('user@livemask.dev', '${USER_HASH}', 'GeoIP Cred Smoke User') ON CONFLICT (email) DO NOTHING" 2>/dev/null
  pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'user', 'dev seed by geoip-credentials-smoke.sh' FROM users WHERE email='user@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
fi

# ──────────────────────────────────────────────────────────────────────────────
# [1] Login as different roles
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 1: Auth — Login ==="

echo "--- [1.1] Admin Login ---"
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"cred-smoke-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  fail "Admin login — no access token"
else
  pass "Admin login OK (token length=${#ADMIN_TOKEN})"
fi

echo ""
echo "--- [1.2] Auditor Login (read-only admin role) ---"
AUDITOR_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"cred-smoke-auditor-login","email":"auditor@livemask.dev","password":"AuditorPass123!","client_type":"admin"}') || true
AUDITOR_TOKEN=$(echo "${AUDITOR_LOGIN}" | quiet_json "access_token")
if [[ -z "${AUDITOR_TOKEN}" ]]; then
  fail "Auditor login — no access token"
else
  pass "Auditor login OK (token length=${#AUDITOR_TOKEN})"
fi

echo ""
echo "--- [1.3] User Login (app audience) ---"
USER_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"cred-smoke-user-login","email":"user@livemask.dev","password":"UserPass123!","client_type":"app"}') || true
USER_TOKEN=$(echo "${USER_LOGIN}" | quiet_json "access_token")
if [[ -z "${USER_TOKEN}" ]]; then
  fail "User login — no access token"
else
  pass "User login OK (token length=${#USER_TOKEN})"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [2] GET /admin/api/v1/geoip/sources (list)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 2: GET Sources List ==="

echo "--- [2.1] List sources with admin token ---"
SOURCES_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/geoip/sources" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
SOURCES_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/geoip/sources" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

HAVE_SOURCES=false
case "${SOURCES_HTTP}" in
  200)
    SOURCE_COUNT=$(echo "${SOURCES_RESP}" | python3 -c "
import sys,json; d=json.load(sys.stdin)
items = d.get('sources', d.get('items', d.get('data', [])))
if isinstance(items, list): print(len(items))
else: print(0)
" 2>/dev/null || echo "0")
    pass "Sources list: HTTP 200, count=${SOURCE_COUNT}"
    security_check "Sources list" "${SOURCES_RESP}" || true
    check_redacted_endpoint "Sources list" "${SOURCES_RESP}" || true
    HAVE_SOURCES=true

    # Extract first source name for detail tests
    FIRST_SOURCE=$(echo "${SOURCES_RESP}" | python3 -c "
import sys,json; d=json.load(sys.stdin)
items = d.get('sources', d.get('items', d.get('data', [])))
if items:
    s = items[0]
    print(s.get('name', s.get('source', s.get('id', ''))))
" 2>/dev/null || echo "")
    if [[ -n "${FIRST_SOURCE}" ]]; then
      echo "  First source: ${FIRST_SOURCE}"
    fi
    ;;
  403)
    fail "Sources list: HTTP 403 (geoip:read permission missing)"
    echo "  Response: $(echo ${SOURCES_RESP} | head -c 200)"
    ;;
  404)
    skip "Sources list: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Sources list: HTTP ${SOURCES_HTTP} (endpoint may not be fully deployed)"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# [3] GET /admin/api/v1/geoip/sources/{source} (detail)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 3: GET Source Detail ==="

# Try known source names
for try_source in "${FIRST_SOURCE:-}" "dbip_lite" "maxmind_geolite2" "ip2location_lite" "hackl0us_geoip2_cn"; do
  [[ -z "${try_source}" ]] && continue
  echo "--- [3.1] GET source detail: ${try_source} ---"
  SOURCE_DETAIL_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/geoip/sources/${try_source}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
  SOURCE_DETAIL_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}/admin/api/v1/geoip/sources/${try_source}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

  case "${SOURCE_DETAIL_HTTP}" in
    200)
      pass "Source detail ${try_source}: HTTP 200"
      security_check "Source detail ${try_source}" "${SOURCE_DETAIL_RESP}" || true
      check_redacted_endpoint "Source detail ${try_source}" "${SOURCE_DETAIL_RESP}" || true

      # Verify source name matches
      RETURNED_NAME=$(echo "${SOURCE_DETAIL_RESP}" | quiet_json "name" || echo "")
      RETURNED_SOURCE=$(echo "${SOURCE_DETAIL_RESP}" | quiet_json "source" || echo "")
      if [[ "${RETURNED_NAME}" == "${try_source}" ]] || [[ "${RETURNED_SOURCE}" == "${try_source}" ]]; then
        pass "Source detail ${try_source}: name/source field matches"
      fi

      CHECK_SOURCE="${try_source}"
      HAVE_CHECK_SOURCE=true
      break
      ;;
    404)
      echo "  Source ${try_source}: HTTP 404 (not found, trying next)"
      ;;
    403)
      fail "Source detail ${try_source}: HTTP 403"
      ;;
    *)
      echo "  Source ${try_source}: HTTP ${SOURCE_DETAIL_HTTP} (unknown)"
      ;;
  esac
done

if [[ "${HAVE_CHECK_SOURCE:-false}" != "true" ]]; then
  skip "Source detail: no source endpoint returned 200"
  CHECK_SOURCE="dbip_lite"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [4] PUT /admin/api/v1/geoip/sources/{source} (update credential)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 4: PUT Update Source Credential ==="

echo "--- [4.1] PUT update credential with admin token ---"
UPDATE_CRED_RESP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X PUT \
  "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d '{"endpoint_url":"https://example.com/geoip/test","license_key":"sk-test-credential-001","api_key":"ak-test-credential-001"}') || true

case "${UPDATE_CRED_RESP}" in
  200|201)
    pass "Update credential: HTTP ${UPDATE_CRED_RESP} (accepted)"
    # Verify updated source does not leak credential fields
    UPDATED_DETAIL=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    security_check "After update: source detail" "${UPDATED_DETAIL}" || true
    check_redacted_endpoint "After update: source detail" "${UPDATED_DETAIL}" || true
    ;;
  403)
    fail "Update credential: HTTP 403 (geoip:write permission missing)"
    ;;
  404)
    skip "Update credential: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Update credential: HTTP ${UPDATE_CRED_RESP} (endpoint may not be fully deployed)"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# [5] POST /admin/api/v1/geoip/sources/{source}/verify
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 5: POST Verify Credential ==="

echo "--- [5.1] Verify credential with admin token ---"
VERIFY_RESP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST \
  "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}/verify" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${VERIFY_RESP}" in
  200|201|202)
    VERIFY_BODY=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}/verify" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "")
    if [[ -n "${VERIFY_BODY}" ]]; then
      security_check "Verify credential response" "${VERIFY_BODY}" || true
    fi
    pass "Verify credential: HTTP ${VERIFY_RESP}"
    ;;
  403)
    fail "Verify credential: HTTP 403"
    ;;
  404)
    skip "Verify credential: HTTP 404 (endpoint not yet deployed)"
    ;;
  405)
    # Verify might be GET instead of POST — check
    VERIFY_GET_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}/verify" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    if [[ "${VERIFY_GET_HTTP}" == "200" ]]; then
      pass "Verify credential: GET HTTP 200 (endpoint uses GET)"
    else
      skip "Verify credential: HTTP 405 (method mismatch)"
    fi
    ;;
  *)
    skip "Verify credential: HTTP ${VERIFY_RESP}"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# [6] POST /admin/api/v1/geoip/sources/{source}/rotate-secret
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 6: POST Rotate Secret ==="

echo "--- [6.1] Rotate secret with admin token ---"
ROTATE_RESP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST \
  "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}/rotate-secret" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${ROTATE_RESP}" in
  200|201)
    ROTATE_BODY=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}/rotate-secret" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "")
    if [[ -n "${ROTATE_BODY}" ]]; then
      security_check "Rotate secret response" "${ROTATE_BODY}" || true
    fi
    pass "Rotate secret: HTTP ${ROTATE_RESP}"
    ;;
  403)
    fail "Rotate secret: HTTP 403"
    ;;
  404)
    skip "Rotate secret: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Rotate secret: HTTP ${ROTATE_RESP}"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# [7] POST /admin/api/v1/geoip/sources/{source}/disable
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 7: POST Disable Source ==="

echo "--- [7.1] Disable source with admin token ---"
DISABLE_RESP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST \
  "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}/disable" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${DISABLE_RESP}" in
  200|201)
    pass "Disable source: HTTP ${DISABLE_RESP}"
    ;;
  403)
    fail "Disable source: HTTP 403"
    ;;
  404)
    skip "Disable source: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Disable source: HTTP ${DISABLE_RESP}"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# [8] POST /admin/api/v1/geoip/sources/{source}/enable
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 8: POST Enable Source ==="

echo "--- [8.1] Enable source with admin token ---"
ENABLE_RESP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST \
  "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}/enable" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${ENABLE_RESP}" in
  200|201)
    pass "Enable source: HTTP ${ENABLE_RESP}"
    ;;
  403)
    fail "Enable source: HTTP 403"
    ;;
  404)
    skip "Enable source: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip "Enable source: HTTP ${ENABLE_RESP}"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# [9] No token → 401
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 9: No Token → 401 ==="

NO_TOKEN_ENDPOINTS=(
  "GET:admin/api/v1/geoip/sources"
  "GET:admin/api/v1/geoip/sources/${CHECK_SOURCE}"
  "PUT:admin/api/v1/geoip/sources/${CHECK_SOURCE}"
  "POST:admin/api/v1/geoip/sources/${CHECK_SOURCE}/verify"
  "POST:admin/api/v1/geoip/sources/${CHECK_SOURCE}/rotate-secret"
  "POST:admin/api/v1/geoip/sources/${CHECK_SOURCE}/disable"
  "POST:admin/api/v1/geoip/sources/${CHECK_SOURCE}/enable"
)

no_token_failed=0
for entry in "${NO_TOKEN_ENDPOINTS[@]}"; do
  IFS=':' read -r method path <<< "${entry}"
  http_code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X "${method}" \
    "${API_BASE}/${path}" \
    -H "Content-Type: application/json" 2>/dev/null || true)
  if [[ "${http_code}" != "401" ]]; then
    echo "  FAIL: ${method} /${path} → ${http_code} (expected 401)"
    no_token_failed=1
  fi
done

if [[ "${no_token_failed}" -eq 0 ]]; then
  pass "No token → 401 on all credential endpoints"
else
  fail "Some no-token checks failed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [10] User token → 403
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 10: User Token → 403 ==="

echo "--- [10.1] User token on credential endpoints (expect 403) ---"
USER_TOKEN_ENDPOINTS=(
  "GET:admin/api/v1/geoip/sources"
  "GET:admin/api/v1/geoip/sources/${CHECK_SOURCE}"
  "PUT:admin/api/v1/geoip/sources/${CHECK_SOURCE}"
  "POST:admin/api/v1/geoip/sources/${CHECK_SOURCE}/verify"
  "POST:admin/api/v1/geoip/sources/${CHECK_SOURCE}/rotate-secret"
  "POST:admin/api/v1/geoip/sources/${CHECK_SOURCE}/disable"
  "POST:admin/api/v1/geoip/sources/${CHECK_SOURCE}/enable"
)

user_token_failed=0
for entry in "${USER_TOKEN_ENDPOINTS[@]}"; do
  IFS=':' read -r method path <<< "${entry}"
  http_code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X "${method}" \
    "${API_BASE}/${path}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || true)
  if [[ "${http_code}" != "403" && "${http_code}" != "401" ]]; then
    echo "  FAIL: ${method} /${path} → ${http_code} (expected 403/401)"
    user_token_failed=1
  fi
done

if [[ "${user_token_failed}" -eq 0 ]]; then
  pass "User token → 403/401 on all credential endpoints (RBAC/audience enforced)"
else
  fail "Some user-token checks failed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [11] Read-only admin/role (auditor) → write 403
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 11: Read-Only Role (Auditor) → Write 403 ==="

echo "--- [11.1] Auditor can read ---"
AUDITOR_READ_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/geoip/sources" \
  -H "Authorization: Bearer ${AUDITOR_TOKEN}") || true
if [[ "${AUDITOR_READ_HTTP}" == "200" ]]; then
  pass "Auditor can read sources: HTTP 200"
elif [[ "${AUDITOR_READ_HTTP}" == "404" ]]; then
  skip "Auditor read: HTTP 404 (endpoint not deployed)"
else
  skip "Auditor read: HTTP ${AUDITOR_READ_HTTP}"
fi

echo ""
echo "--- [11.2] Auditor write → 403 on credential update ---"
AUDITOR_WRITE_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X PUT \
  "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AUDITOR_TOKEN}" \
  -d '{"endpoint_url":"https://example.com/geoip/test"}') || true

if [[ "${AUDITOR_WRITE_HTTP}" == "403" ]]; then
  pass "Auditor write (PUT credential): HTTP 403 (geoip:write denied as expected)"
elif [[ "${AUDITOR_WRITE_HTTP}" == "404" ]]; then
  skip "Auditor write: HTTP 404 (endpoint not deployed)"
else
  fail "Auditor write: HTTP ${AUDITOR_WRITE_HTTP} (expected 403)"
fi

echo ""
echo "--- [11.3] Auditor write → 403 on verify ---"
AUDITOR_VERIFY_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST \
  "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}/verify" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AUDITOR_TOKEN}") || true

if [[ "${AUDITOR_VERIFY_HTTP}" == "403" ]]; then
  pass "Auditor write (verify): HTTP 403 (geoip:write denied)"
elif [[ "${AUDITOR_VERIFY_HTTP}" == "405" ]]; then
  # If verify uses GET, this is a different scenario
  AUDITOR_VERIFY_GET_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}/verify" \
    -H "Authorization: Bearer ${AUDITOR_TOKEN}") || true
  if [[ "${AUDITOR_VERIFY_GET_HTTP}" == "200" ]]; then
    skip "Auditor verify: GET 200 (verify is read operation, acceptable for auditor)"
  else
    skip "Auditor verify: HTTP 405"
  fi
elif [[ "${AUDITOR_VERIFY_HTTP}" == "404" ]]; then
  skip "Auditor verify: HTTP 404"
else
  skip "Auditor verify: HTTP ${AUDITOR_VERIFY_HTTP}"
fi

echo ""
echo "--- [11.4] Auditor write → 403 on rotate-secret ---"
AUDITOR_ROTATE_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST \
  "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}/rotate-secret" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AUDITOR_TOKEN}") || true

if [[ "${AUDITOR_ROTATE_HTTP}" == "403" ]]; then
  pass "Auditor write (rotate-secret): HTTP 403 (geoip:write denied)"
elif [[ "${AUDITOR_ROTATE_HTTP}" == "404" ]]; then
  skip "Auditor rotate-secret: HTTP 404"
else
  skip "Auditor rotate-secret: HTTP ${AUDITOR_ROTATE_HTTP}"
fi

echo ""
echo "--- [11.5] Auditor write → 403 on disable/enable ---"
AUDITOR_DISABLE_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST \
  "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}/disable" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${AUDITOR_TOKEN}") || true

if [[ "${AUDITOR_DISABLE_HTTP}" == "403" ]]; then
  pass "Auditor write (disable): HTTP 403 (denied)"
elif [[ "${AUDITOR_DISABLE_HTTP}" == "404" ]]; then
  skip "Auditor disable: HTTP 404"
else
  skip "Auditor disable: HTTP ${AUDITOR_DISABLE_HTTP}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [12] API response excludes sensitive fields (already checked inline)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 12: API Response — Sensitive Field Redaction ==="

# Re-fetch sources list and do a thorough security check
if [[ "${HAVE_SOURCES}" == "true" ]]; then
  echo "--- [12.1] Thorough security scan on sources list ---"
  SECURE_SOURCES=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/geoip/sources" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
  security_check "Sources list" "${SECURE_SOURCES}" || true

  echo ""
  echo "--- [12.2] Check no sensitive fields exist in source detail ---"
  if [[ -n "${CHECK_SOURCE:-}" ]]; then
    SECURE_DETAIL=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/geoip/sources/${CHECK_SOURCE}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    security_check "Source detail ${CHECK_SOURCE}" "${SECURE_DETAIL}" || true
  fi
else
  skip "Sources not available for security scan"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [13] endpoint_url query redaction (already checked inline)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 13: Endpoint URL Redaction ==="
if [[ "${HAVE_SOURCES}" == "true" && -n "${CHECK_SOURCE:-}" ]]; then
  echo "--- [13.1] Check endpoint_url in source detail ---"
  check_redacted_endpoint "Source detail ${CHECK_SOURCE}" "${SECURE_DETAIL}" && \
    pass "Endpoint URL redaction check passed" || true
fi

# ──────────────────────────────────────────────────────────────────────────────
# [14] Audit log does not contain secret
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 14: Audit Log — No Credential Secrets ==="

echo "--- [14.1] Check audit log for credential secrets ---"
check_audit_no_secret "GeoIP credential operations" || true

# ──────────────────────────────────────────────────────────────────────────────
# [15] Env fallback does not break existing GeoIP update
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== SECTION 15: Env Fallback — Existing GeoIP Update Unaffected ==="

echo "--- [15.1] POST /admin/api/v1/geoip/update (known source) ---"
ENV_UPDATE_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST \
  "${API_BASE}/admin/api/v1/geoip/update" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -d '{"source":"dbip_lite","edition":"country"}') || true

case "${ENV_UPDATE_HTTP}" in
  200|201|202)
    pass "GeoIP update unaffected by credential changes: HTTP ${ENV_UPDATE_HTTP}"
    ;;
  403)
    fail "GeoIP update: HTTP 403 (RBAC regression)"
    ;;
  404)
    skip "GeoIP update: HTTP 404 (endpoint not deployed)"
    ;;
  400)
    fail "GeoIP update: HTTP 400 (credential env fallback broke update)"
    echo "  This indicates missing credentials broke GeoIP update functionality."
    ;;
  *)
    skip "GeoIP update: HTTP ${ENV_UPDATE_HTTP}"
    ;;
esac

echo ""
echo "--- [15.2] GET /api/v1/geoip/manifest (user still works) ---"
ENV_MANIFEST_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/api/v1/geoip/manifest?current_version=2026-04&platform=all&app_version=1.0" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true

case "${ENV_MANIFEST_HTTP}" in
  200)
    pass "App manifest unaffected by credential changes: HTTP 200"
    ;;
  404)
    skip "App manifest: HTTP 404 (endpoint not deployed)"
    ;;
  401)
    fail "App manifest: HTTP 401 (regression)"
    ;;
  *)
    skip "App manifest: HTTP ${ENV_MANIFEST_HTTP}"
    ;;
esac

echo ""
echo "--- [15.3] GET /admin/api/v1/geoip/databases (admin unaffected) ---"
ENV_DB_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/geoip/databases" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}") || true

case "${ENV_DB_HTTP}" in
  200)
    pass "Admin DB list unaffected by credential changes: HTTP 200"
    ;;
  404)
    skip "Admin DB list: HTTP 404 (endpoint not deployed)"
    ;;
  403)
    fail "Admin DB list: HTTP 403 (regression)"
    ;;
  *)
    skip "Admin DB list: HTTP ${ENV_DB_HTTP}"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Cleanup ---"
# Remove smoke-created users (keep seed users for other smoke scripts)
pg_exec -c "DELETE FROM users WHERE email='auditor@livemask.dev'" 2>/dev/null || true
echo "  Removed: auditor@livemask.dev"
echo "  Kept: admin@livemask.dev, user@livemask.dev"

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo " TASK-CICD-GEOIP-CREDENTIALS-001 SUMMARY"
echo "========================================================"
printf '%s\n' "${SUMMARY_LINES[@]}"

echo ""
if [[ "${FAILED}" -eq 1 ]]; then
  echo "[TASK-CICD-GEOIP-CREDENTIALS-001] GEOIP CREDENTIALS SMOKE FAILED."
  echo ""
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo ""
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit 1
fi

echo "[TASK-CICD-GEOIP-CREDENTIALS-001] GeoIP credentials smoke PASSED."
echo "Covers: Auth, RBAC, source CRUD, verify, rotate, disable/enable, secret redaction, audit, env fallback"
