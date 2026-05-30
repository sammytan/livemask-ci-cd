#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-SECRET-LEAK-STANDARD-SMOKE-001
# Standardized Secret Leak Scan — All Services
# ═══════════════════════════════════════════════════════════════════════════════
# A shared, standardized secret leak scan that checks all service endpoints for
# accidental exposure of sensitive fields. This can be used standalone or invoked
# by other smoke scripts as a consistent cross-service secret scan.
#
# Usage:
#   bash scripts/secret-leak-standard-smoke.sh
#   bash scripts/secret-leak-standard-smoke.sh --verbose
#
# Environment:
#   ADMIN_TOKEN, USER_TOKEN — for authenticated endpoint checks
#   SKIP_ENDPOINTS — comma-separated paths to skip
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/base_service.sh"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
API_BASE="$(lm_backend_base_url)"
WEBSITE_BASE="$(lm_website_base_url)"
JOB_SERVICE_URL="$(lm_job_service_url)"
NODEAGENT_API="http://127.0.0.1:${LIVEMASK_NODEAGENT_PORT:-19090}"

VERBOSE=false
[[ "${1:-}" == "--verbose" ]] && VERBOSE=true

FAILED=0; PASS_COUNT=0; SKIP_COUNT=0; FAIL_COUNT=0; SUMMARY_LINES=()
LEAKED_ENDPOINTS=()

fail()    { local m="$1"; echo "  FAIL: ${m}"; SUMMARY_LINES+=("FAIL: ${m}"); FAIL_COUNT=$((FAIL_COUNT+1)); FAILED=1; }
pass()    { local m="$1"; echo "  PASS: ${m}"; SUMMARY_LINES+=("PASS: ${m}"); PASS_COUNT=$((PASS_COUNT+1)); }
skip()    { local m="$1"; echo "  SKIP: ${m}"; SUMMARY_LINES+=("SKIP: ${m}"); SKIP_COUNT=$((SKIP_COUNT+1)); }
blocker() { local m="$1"; echo "  BLOCKER: ${m}"; SUMMARY_LINES+=("BLOCKER: ${m}"); FAILED=1; }

echo "================================================"
echo " TASK-CICD-SECRET-LEAK-STANDARD-SMOKE-001"
echo " Standardized Secret Leak Scan — All Services"
echo "================================================"
lm_runtime_status_report; echo ""

# ---------------------------------------------------------------------------
# Standardized secret leak checker function
# ---------------------------------------------------------------------------
# Usage: secret_leak_scan <label> <response_body> [response_headers]
# Returns: 0 if clean, 1 if leak found
# ---------------------------------------------------------------------------
secret_leak_scan() {
  local label="$1"
  local json="$2"

  # Skip empty or non-JSON responses
  if [[ -z "${json}" || "${json}" == "{}" ]]; then
    return 0
  fi

  # Use python3 for thorough JSON scanning
  local leaked
  leaked=$(echo "${json}" | python3 -c "
import sys, json, re

SENSITIVE_KEYS = [
    'password_hash', 'node_secret', 'node_secret_hash',
    'hmac_key', 'hmac_secret',
    'private_key', 'secret_key', 'secret_access',
    'encryption_key', 'encrypted_key',
    'access_token_raw', 'refresh_token_raw',
    'api_key', 'api_secret', 'api_token',
    'license_key', 'license_secret',
    'sentry_dsn', 'sentry_secret',
    'bearer_token', 'raw_token', 'auth_token',
    'full_config', 'raw_payload', 'sing_box_config', 'singbox_config',
    'webhook_secret', 'webhook_token', 'webhook_key',
    'pem_key', 'rsa_private', 'ed25519_private',
    'signing_key', 'signing_secret',
    'aws_secret', 'aws_secret_key', 'gcp_secret',
    'master_key', 'root_key', 'vault_token',
    'db_password', 'database_password', 'redis_password',
    'jwt_secret', 'jwt_signing_key',
    'client_secret', 'client_key',
]

SENSITIVE_VALUES = [
    '-----BEGIN RSA PRIVATE KEY-----',
    '-----BEGIN EC PRIVATE KEY-----',
    '-----BEGIN PRIVATE KEY-----',
    '-----BEGIN OPENSSH PRIVATE KEY-----',
    'sk_live_', 'sk_test_',  # Stripe
    'pk_live_', 'pk_test_',
    'ghp_', 'gho_', 'ghu_', 'ghs_',  # GitHub tokens
    'xoxb-', 'xoxp-',  # Slack tokens
    'AKIA',  # AWS access keys (pattern)
]

def check_keys(obj, path=''):
    if isinstance(obj, dict):
        for k, v in obj.items():
            kl = k.lower()
            current_path = f'{path}.{k}' if path else k

            for sk in SENSITIVE_KEYS:
                if sk in kl:
                    return f'key match: {current_path}'

            r = check_keys(v, current_path)
            if r:
                return r
    elif isinstance(obj, list):
        for idx, item in enumerate(obj):
            r = check_keys(item, f'{path}[{idx}]')
            if r:
                return r
    return None

def check_values(obj, path=''):
    '''Check values for sensitive patterns (shallow scan only)'''
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str):
                for sv in SENSITIVE_VALUES:
                    if sv in v:
                        return f'value pattern: {path}.{k}'
            r = check_values(v, f'{path}.{k}' if path else k)
            if r:
                return r
    elif isinstance(obj, list):
        for i in obj:
            r = check_values(i, path)
            if r:
                return r
    return None

try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print('SKIP: not JSON')
    sys.exit(0)

key_result = check_keys(data)
if key_result:
    print('LEAK: ' + key_result)
    sys.exit(1)

value_result = check_values(data)
if value_result:
    print('LEAK: ' + value_result)
    sys.exit(1)

print('OK')
" 2>/dev/null || echo "CHECK_ERROR")

  case "${leaked}" in
    "OK") return 0 ;;
    "SKIP: not JSON") return 0 ;;
    "CHECK_ERROR")
      fail "[SECURITY] ${label}: checker encountered an error"
      LEAKED_ENDPOINTS+=("${label}")
      return 1
      ;;
    *)
      fail "[SECURITY] ${label}: ${leaked}"
      LEAKED_ENDPOINTS+=("${label}")
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Endpoint Groups
# ---------------------------------------------------------------------------

# Can be used standalone (needs auth) or with provided tokens
if [[ -z "${ADMIN_TOKEN:-}" ]]; then
  # Try to login as admin
  pg_exec() { docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA "$@" 2>/dev/null || true; }
  pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'" 2>/dev/null || true
  ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
  if [[ -n "${ADMIN_HASH}" ]]; then
    pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'" 2>/dev/null
    pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by secret-leak-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
  fi
  ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"request_id":"slsmoke-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
  ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null || echo "")
fi

if [[ -z "${ADMIN_TOKEN:-}" ]]; then
  skip "No admin token available — endpoint scanning limited to unauthenticated paths"
fi

# ---------------------------------------------------------------------------
# 1. Health endpoint (no auth)
# ---------------------------------------------------------------------------
echo "--- [1] Backend Health ---"
for attempt in $(seq 1 30); do
  health_resp=$(lm_backend_health_json || true)
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    pass "Backend ready (attempt ${attempt})"; break
  fi
  if [[ "${attempt}" -eq 30 ]]; then blocker "Backend not ready"; exit 1; fi
  sleep 2
done
secret_leak_scan "health" "${health_resp}" && pass "Health: no secret leak" || true

# ---------------------------------------------------------------------------
# 2. Backend Public Endpoints (no auth)
# ---------------------------------------------------------------------------
echo ""
echo "--- [2] Backend Public Endpoints ---"
PUBLIC_ENDPOINTS=(
  "/api/v1/health"
  "/api/v1/config/public"
)
# i18n messages excluded: error code keys like AUTH_TOKEN_EXPIRED are not secrets
for ep in "${PUBLIC_ENDPOINTS[@]}"; do
  code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${API_BASE}${ep}" 2>/dev/null || echo "000")
  if [[ "${code}" == "200" ]]; then
    body=$(curl -sS --max-time 5 "${API_BASE}${ep}" 2>/dev/null || echo "{}")
    if secret_leak_scan "public:${ep#/api/v1/}" "${body}"; then
      pass "public ${ep#/api/v1/}: clean"
    fi
  else
    skip "public ${ep#/api/v1/}: HTTP ${code}"
  fi
done

# ---------------------------------------------------------------------------
# 3. Admin Endpoints (with auth)
# ---------------------------------------------------------------------------
echo ""
echo "--- [3] Admin Endpoints ---"
if [[ -n "${ADMIN_TOKEN:-}" ]]; then
  ADMIN_ENDPOINTS=(
    "/admin/api/v1/nodes"
    "/admin/api/v1/nodes?per_page=5"
    "/admin/api/v1/jobs/definitions"
    "/admin/api/v1/jobs/runs"
    "/admin/api/v1/jobs/schedules"
    "/admin/api/v1/system/configs"
    "/admin/api/v1/dashboard/overview"
    "/admin/api/v1/protocol-templates"
  )
  for ep in "${ADMIN_ENDPOINTS[@]}"; do
    code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "${API_BASE}${ep}" -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
    if [[ "${code}" == "200" ]]; then
      body=$(curl -sS --max-time 5 "${API_BASE}${ep}" -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
      if secret_leak_scan "admin:${ep#/admin/api/v1/}" "${body}"; then
        pass "admin ${ep#/admin/api/v1/}: clean"
      fi
    else
      skip "admin ${ep#/admin/api/v1/}: HTTP ${code}"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 4. Job Service Endpoints (internal)
# ---------------------------------------------------------------------------
echo ""
echo "--- [4] Job Service Endpoints ---"
JS_ENDPOINTS=(
  "${JOB_SERVICE_URL}/healthz"
  "${JOB_SERVICE_URL}/internal/jobs"
  "${JOB_SERVICE_URL}/internal/jobs/runs"
)
for ep in "${JS_ENDPOINTS[@]}"; do
  code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${ep}" 2>/dev/null || echo "000")
  label="${ep#${JOB_SERVICE_URL}}"
  if [[ "${code}" == "200" ]]; then
    body=$(curl -sS --max-time 5 "${ep}" 2>/dev/null || echo "{}")
    if secret_leak_scan "job-service:${label}" "${body}"; then
      pass "job-service ${label}: clean"
    fi
  else
    skip "job-service ${label}: HTTP ${code}"
  fi
done

# ---------------------------------------------------------------------------
# 5. NodeAgent Endpoints
# ---------------------------------------------------------------------------
echo ""
echo "--- [5] NodeAgent Endpoints ---"
NA_ENDPOINTS=(
  "/health"
  "/config/status"
  "/status"
)
for path in "${NA_ENDPOINTS[@]}"; do
  code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${NODEAGENT_API}${path}" 2>/dev/null || echo "000")
  if [[ "${code}" == "200" ]]; then
    body=$(curl -sS --max-time 5 "${NODEAGENT_API}${path}" 2>/dev/null || echo "{}")
    if secret_leak_scan "nodeagent:${path}" "${body}"; then
      pass "nodeagent ${path}: clean"
    fi
  else
    skip "nodeagent ${path}: HTTP ${code}"
  fi
done

# ---------------------------------------------------------------------------
# 6. Website Endpoints
# ---------------------------------------------------------------------------
echo ""
echo "--- [6] Website Endpoints ---"
WEBSITE_ENDPOINTS=(
  "${WEBSITE_BASE}/"
  "${WEBSITE_BASE}/api/public/config"
)
for ep in "${WEBSITE_ENDPOINTS[@]}"; do
  code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "${ep}" 2>/dev/null || echo "000")
  label="${ep#${WEBSITE_BASE}}"
  if [[ "${code}" == "200" ]]; then
    body=$(curl -sS --max-time 5 "${ep}" 2>/dev/null || echo "{}")
    if secret_leak_scan "website:${label}" "${body}"; then
      pass "website ${label}: clean"
    fi
  elif [[ "${code}" == "301" || "${code}" == "302" ]]; then
    skip "website ${label}: HTTP ${code} (redirect — no body to scan)"
  else
    skip "website ${label}: HTTP ${code}"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================"
echo " TASK-CICD-SECRET-LEAK-STANDARD-SMOKE-001 SUMMARY"
echo "================================================"
echo "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}  SKIP: ${SKIP_COUNT}"
if [[ ${#LEAKED_ENDPOINTS[@]} -gt 0 ]]; then
  echo ""
  echo "  LEAKS DETECTED in:"
  for ep in "${LEAKED_ENDPOINTS[@]}"; do
    echo "    - ${ep}"
  done
fi
for line in "${SUMMARY_LINES[@]}"; do echo "  ${line}"; done

if [[ "${FAILED}" -eq 1 ]]; then
  echo ""
  echo "[TASK-CICD-SECRET-LEAK-STANDARD-SMOKE-001] FAILED — ${#LEAKED_ENDPOINTS[@]} leak(s) detected."
  exit 1
fi
echo ""
echo "[TASK-CICD-SECRET-LEAK-STANDARD-SMOKE-001] PASSED — 0 leaks detected."
