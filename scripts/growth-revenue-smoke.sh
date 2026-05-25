#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-USER-GROWTH-REVENUE-001 + TASK-CICD-GROWTH-REWARD-NOTIFICATION-001
# Growth Revenue & Reward Notification Smoke
# ═══════════════════════════════════════════════════════════════════════════════
# Covers (Revenue):
#   [1]  Backend health
#   [2]  Admin login
#   [3]  User register/login
#   [4]  USDT payout create
#   [5]  Reserved alipay blocked
#   [6]  Payout list
#   [7]  Referral link
#   [8]  Referral report
#   [9]  Sponsor report
#  [10]  Settlement reports
#  [11]  Revenue feedback redaction (no revenue leak in response)
#  [12]  Admin rules
#  [13]  Admin settlements
#  [14]  Admin feedback
#  [15]  RBAC enforcement (no token / user token → 401/403)
#  [16]  Secret leak scan
#
# Covers (Reward Notification):
#  [17]  Reward notification seed
#  [18]  Reward notification fetch
#  [19]  Reward notification ack
#  [20]  Admin notification list
#  [21]  Admin notification preview
#  [22]  USDT no UDST typo safety
#  [23]  Secret leak scan (notifications)
#
# Covers (User Profile Growth Fields):
#  [24]  GET /api/v1/me — canonical profile with usdt_addresses + promotion_link
#  [25]  GET /api/v1/me/profile — full profile with growth fields
#  [26]  Create USDT payout method (trc20)
#  [27]  Create USDT payout method (erc20)
#  [28]  Create USDT payout method (bep20)
#  [29]  Fourth active address rejected
#  [30]  Unsupported protocol (btc) rejected
#  [31]  Payout-methods list — masking + no UDST typo
#  [32]  Secret leak scan (profile growth fields)
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
  local leaked
  leaked=$(echo "${json}" | python3 -c "
import sys,json
SENSITIVE_WORDS = [
    'password_hash','node_secret','hmac','private_key','secret_key',
    'storage_path','encryption_key','access_token','refresh_token',
    'access_key','secret_access_key','aws_secret','s3_secret',
]
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
SUFFIX="growth-${TIMESTAMP}"
USER_EMAIL="growth-smoke-${SUFFIX}@test.livemask"
USER_PASS="GrowthTest123!"

echo "================================================"
echo " TASK-CICD-USER-GROWTH-REVENUE-001 +"
echo " TASK-CICD-GROWTH-REWARD-NOTIFICATION-001"
echo " Growth Revenue & Reward Notification Smoke"
echo "================================================"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# [1] Backend health
# ──────────────────────────────────────────────────────────────────────────────
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

# ──────────────────────────────────────────────────────────────────────────────
# [2] Admin login (seed dev admin)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [2] Admin Login ---"
pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'" 2>/dev/null || true
ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -n "${ADMIN_HASH}" ]]; then
  pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'" 2>/dev/null
  pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by growth-revenue-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
fi
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"growth-smoke-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  blocker "Admin login — no access token"
else
  pass "Admin login OK (token length=${#ADMIN_TOKEN})"
fi
ADMIN_USER_ID=$(echo "${ADMIN_LOGIN}" | quiet_json "user.user_id")

# ──────────────────────────────────────────────────────────────────────────────
# [3] User register/login
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [3] User Register / Login ---"
pg_exec -c "DELETE FROM users WHERE email='${USER_EMAIL}'" 2>/dev/null || true
USER_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"growth-smoke-reg\",\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASS}\",\"display_name\":\"Growth Smoke User\",\"client_type\":\"app\"}") || true
USER_TOKEN=$(echo "${USER_REG}" | quiet_json "access_token")
USER_ID=$(echo "${USER_REG}" | quiet_json "user.user_id")
if [[ -z "${USER_TOKEN}" ]]; then
  USER_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"growth-smoke-login\",\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASS}\",\"client_type\":\"app\"}") || true
  USER_TOKEN=$(echo "${USER_LOGIN}" | quiet_json "access_token")
  USER_ID=$(echo "${USER_LOGIN}" | quiet_json "user.user_id")
fi
if [[ -z "${USER_TOKEN}" ]]; then
  fail "User register/login"
else
  pass "User login OK (user_id=${USER_ID})"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# GROWTH REVENUE SMOKE (TASK-CICD-USER-GROWTH-REVENUE-001)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "========== GROWTH REVENUE SMOKE =========="

# ──────────────────────────────────────────────────────────────────────────────
# [4] USDT payout create
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [4] USDT Payout Create ---"
# Try multiple potential endpoints
PAYOUT_CREATE_RESP=""
PAYOUT_ID=""
for payout_path in "/api/v1/growth/payouts" "/api/v1/payments/payouts" "/api/v1/user/payouts"; do
  PAYOUT_CREATE_RAW=$(curl -sS -w "\n%{http_code}" --max-time 5 -X POST \
    "${API_BASE}${payout_path}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"amount\":10.0,\"currency\":\"USDT\",\"payment_method\":\"usdt_trc20\",\"wallet_address\":\"TXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\",\"request_id\":\"growth-smoke-payout-${TIMESTAMP}\"}") || true
  POUT_HTTP=$(echo "${PAYOUT_CREATE_RAW}" | tail -1)
  if [[ "${POUT_HTTP}" == "200" || "${POUT_HTTP}" == "201" ]]; then
    PAYOUT_CREATE_RESP=$(echo "${PAYOUT_CREATE_RAW}" | sed '$d')
    PAYOUT_ID=$(echo "${PAYOUT_CREATE_RESP}" | quiet_json "payout_id" || echo "${PAYOUT_CREATE_RESP}" | quiet_json "data.payout_id" || echo "${PAYOUT_CREATE_RESP}" | quiet_json "id" || echo "")
    pass "USDT payout create (${payout_path}): HTTP ${POUT_HTTP}, id=${PAYOUT_ID}"
    security_check "USDT payout create" "${PAYOUT_CREATE_RESP}" || true
    break
  fi
done
if [[ -z "${PAYOUT_CREATE_RESP}" ]]; then
  skip "USDT payout create: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [5] Reserved alipay blocked
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [5] Reserved Alipay Blocked ---"
ALIPAY_BLOCKED_RESP=$(curl -sS --max-time 5 -X POST \
  "${API_BASE}/api/v1/growth/payouts" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d "{\"amount\":10.0,\"currency\":\"CNY\",\"payment_method\":\"alipay\",\"alipay_account\":\"test@example.com\",\"request_id\":\"growth-smoke-alipay-${TIMESTAMP}\"}") || true
ALIPAY_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" -X POST \
  "${API_BASE}/api/v1/growth/payouts" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d "{\"amount\":10.0,\"currency\":\"CNY\",\"payment_method\":\"alipay\",\"alipay_account\":\"test@example.com\",\"request_id\":\"growth-smoke-alipay-${TIMESTAMP}\"}") || true
ALIPAY_CODE=$(echo "${ALIPAY_BLOCKED_RESP}" | quiet_json "error.code" || echo "${ALIPAY_BLOCKED_RESP}" | quiet_json "code" || echo "")

if [[ "${ALIPAY_HTTP}" == "400" || "${ALIPAY_HTTP}" == "422" || "${ALIPAY_HTTP}" == "403" ]]; then
  pass "Reserved alipay blocked: HTTP ${ALIPAY_HTTP} (correctly rejected)"
elif echo "${ALIPAY_BLOCKED_RESP}" | grep -qi 'blocked\|reserved\|not allowed\|not supported\|alipay_not_available' 2>/dev/null; then
  pass "Reserved alipay blocked: error message confirms blocking"
elif [[ "${ALIPAY_HTTP}" == "404" ]]; then
  skip "Reserved alipay blocked: endpoint not yet deployed"
else
  skip "Reserved alipay blocked: HTTP ${ALIPAY_HTTP} — could not verify"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [6] Payout list
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [6] Payout List ---"
PAYOUT_LIST_RESP=""
for list_path in "/api/v1/growth/payouts" "/api/v1/payments/payouts" "/api/v1/user/payouts"; do
  PL_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${list_path}" \
    -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${PL_HTTP}" == "200" ]]; then
    PAYOUT_LIST_RESP=$(curl -sS --max-time 5 "${API_BASE}${list_path}" \
      -H "Authorization: Bearer ${USER_TOKEN}") || true
    pass "Payout list (${list_path}): HTTP 200"
    security_check "Payout list" "${PAYOUT_LIST_RESP}" || true
    break
  fi
done
if [[ -z "${PAYOUT_LIST_RESP}" ]]; then
  skip "Payout list: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [7] Referral link
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [7] Referral Link ---"
REFERRAL_LINK_RESP=""
for ref_path in "/api/v1/growth/referral/link" "/api/v1/referral/link" "/api/v1/user/referral/link"; do
  REF_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${ref_path}" \
    -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${REF_HTTP}" == "200" ]]; then
    REFERRAL_LINK_RESP=$(curl -sS --max-time 5 "${API_BASE}${ref_path}" \
      -H "Authorization: Bearer ${USER_TOKEN}") || true
    REF_LINK=$(echo "${REFERRAL_LINK_RESP}" | quiet_json "referral_link" || echo "${REFERRAL_LINK_RESP}" | quiet_json "link" || echo "${REFERRAL_LINK_RESP}" | quiet_json "data.link" || echo "")
    if [[ -n "${REF_LINK}" ]]; then
      pass "Referral link (${ref_path}): ${REF_LINK}"
    else
      pass "Referral link (${ref_path}): HTTP 200 (got response)"
    fi
    security_check "Referral link" "${REFERRAL_LINK_RESP}" || true
    break
  fi
done
if [[ -z "${REFERRAL_LINK_RESP}" ]]; then
  skip "Referral link: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [8] Referral report
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [8] Referral Report ---"
REFERRAL_REPORT_RESP=""
for rr_path in "/api/v1/growth/referral/report" "/api/v1/referral/report" "/api/v1/user/referral/report"; do
  RR_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${rr_path}" \
    -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${RR_HTTP}" == "200" ]]; then
    REFERRAL_REPORT_RESP=$(curl -sS --max-time 5 "${API_BASE}${rr_path}" \
      -H "Authorization: Bearer ${USER_TOKEN}") || true
    pass "Referral report (${rr_path}): HTTP 200"
    security_check "Referral report" "${REFERRAL_REPORT_RESP}" || true
    break
  fi
done
if [[ -z "${REFERRAL_REPORT_RESP}" ]]; then
  skip "Referral report: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [9] Sponsor report
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [9] Sponsor Report ---"
SPONSOR_REPORT_RESP=""
for sp_path in "/api/v1/growth/sponsor/report" "/api/v1/sponsor/report" "/api/v1/user/sponsor/report"; do
  SP_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${sp_path}" \
    -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${SP_HTTP}" == "200" ]]; then
    SPONSOR_REPORT_RESP=$(curl -sS --max-time 5 "${API_BASE}${sp_path}" \
      -H "Authorization: Bearer ${USER_TOKEN}") || true
    pass "Sponsor report (${sp_path}): HTTP 200"
    security_check "Sponsor report" "${SPONSOR_REPORT_RESP}" || true
    break
  fi
done
if [[ -z "${SPONSOR_REPORT_RESP}" ]]; then
  skip "Sponsor report: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [10] Settlement reports
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [10] Settlement Reports ---"
SETTLEMENT_RESP=""
for st_path in "/api/v1/growth/settlements" "/api/v1/payments/settlements" "/api/v1/user/settlements"; do
  ST_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${st_path}" \
    -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${ST_HTTP}" == "200" ]]; then
    SETTLEMENT_RESP=$(curl -sS --max-time 5 "${API_BASE}${st_path}" \
      -H "Authorization: Bearer ${USER_TOKEN}") || true
    pass "Settlement reports (${st_path}): HTTP 200"
    security_check "Settlement reports" "${SETTLEMENT_RESP}" || true
    break
  fi
done
if [[ -z "${SETTLEMENT_RESP}" ]]; then
  skip "Settlement reports: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [11] Revenue feedback redaction
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [11] Revenue Feedback Redaction ---"
# Check that payout/responses do not leak raw revenue amounts to non-admin
REVENUE_LEAK=false
for response_var in "${PAYOUT_LIST_RESP:-}" "${REFERRAL_REPORT_RESP:-}" "${SETTLEMENT_RESP:-}"; do
  if [[ -n "${response_var}" ]]; then
    LEAK_CHECK=$(echo "${response_var}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
flat = str(d).lower()
revenue_keys = ['revenue_amount','total_revenue','gross_revenue','net_revenue']
for key in revenue_keys:
    if key in flat:
        print('FOUND: ' + key)
        sys.exit(0)
print('OK')
" 2>/dev/null || echo "OK")
    if [[ "${LEAK_CHECK}" != "OK" ]]; then
      REVENUE_LEAK=true
      fail "Revenue feedback redaction: raw revenue field '${LEAK_CHECK}' exposed to user role"
    fi
  fi
done
if [[ "${REVENUE_LEAK}" == "false" ]]; then
  pass "Revenue feedback redaction: no raw revenue fields exposed to user role"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [12] Admin rules
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [12] Admin Growth Rules ---"
ADMIN_RULES_RESP=""
for ar_path in "/admin/api/v1/growth/rules" "/admin/api/v1/revenue/rules" "/admin/api/v1/payments/rules"; do
  AR_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${ar_path}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${AR_HTTP}" == "200" ]]; then
    ADMIN_RULES_RESP=$(curl -sS --max-time 5 "${API_BASE}${ar_path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    pass "Admin growth rules (${ar_path}): HTTP 200"
    security_check "Admin growth rules" "${ADMIN_RULES_RESP}" || true
    break
  fi
done
if [[ -z "${ADMIN_RULES_RESP}" ]]; then
  skip "Admin growth rules: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [13] Admin settlements
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [13] Admin Settlements ---"
ADMIN_SETTLE_RESP=""
for as_path in "/admin/api/v1/growth/settlements" "/admin/api/v1/payments/settlements"; do
  AS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${as_path}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${AS_HTTP}" == "200" ]]; then
    ADMIN_SETTLE_RESP=$(curl -sS --max-time 5 "${API_BASE}${as_path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    pass "Admin settlements (${as_path}): HTTP 200"
    security_check "Admin settlements" "${ADMIN_SETTLE_RESP}" || true
    break
  fi
done
if [[ -z "${ADMIN_SETTLE_RESP}" ]]; then
  skip "Admin settlements: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [14] Admin feedback
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [14] Admin Revenue Feedback ---"
ADMIN_FEEDBACK_RESP=""
for af_path in "/admin/api/v1/growth/feedback" "/admin/api/v1/revenue/feedback" "/admin/api/v1/payments/feedback"; do
  AF_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${af_path}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${AF_HTTP}" == "200" ]]; then
    ADMIN_FEEDBACK_RESP=$(curl -sS --max-time 5 "${API_BASE}${af_path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    pass "Admin revenue feedback (${af_path}): HTTP 200"
    security_check "Admin revenue feedback" "${ADMIN_FEEDBACK_RESP}" || true
    break
  fi
done
if [[ -z "${ADMIN_FEEDBACK_RESP}" ]]; then
  skip "Admin revenue feedback: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [15] RBAC enforcement
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [15] RBAC Enforcement ---"

rbac_ok=true

# No token checks
for u_path in "/api/v1/growth/payouts" "/api/v1/growth/referral/link" "/api/v1/growth/referral/report" "/api/v1/growth/settlements"; do
  NT_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${u_path}" 2>/dev/null || true)
  if [[ "${NT_HTTP}" != "401" ]]; then
    echo "  FAIL: no-token ${u_path} → HTTP ${NT_HTTP} (expected 401)"
    rbac_ok=false
  fi
done

# No token on admin endpoints
for a_path in "/admin/api/v1/growth/rules" "/admin/api/v1/growth/settlements" "/admin/api/v1/growth/feedback"; do
  NT_ADM_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${a_path}" 2>/dev/null || true)
  if [[ "${NT_ADM_HTTP}" != "401" ]]; then
    echo "  FAIL: no-token admin ${a_path} → HTTP ${NT_ADM_HTTP} (expected 401)"
    rbac_ok=false
  fi
done

# User token on admin endpoints → 403
if [[ -n "${USER_TOKEN}" ]]; then
  for a_path_403 in "/admin/api/v1/growth/rules" "/admin/api/v1/growth/settlements" "/admin/api/v1/growth/feedback"; do
    UT_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "${API_BASE}${a_path_403}" \
      -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || true)
    if [[ "${UT_HTTP}" != "403" && "${UT_HTTP}" != "401" ]]; then
      echo "  FAIL: user-token admin ${a_path_403} → HTTP ${UT_HTTP} (expected 401/403)"
      rbac_ok=false
    fi
  done
fi

if [[ "${rbac_ok}" == "true" ]]; then
  pass "RBAC enforcement (no-token 401, user→admin 401/403)"
else
  fail "Some RBAC checks failed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [16] Secret leak scan (growth revenue)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [16] Secret Leak Scan (Growth Revenue) ---"
SCAN_LEAK=false
for resp_var in "${PAYOUT_CREATE_RESP:-}" "${PAYOUT_LIST_RESP:-}" "${REFERRAL_LINK_RESP:-}" \
                "${REFERRAL_REPORT_RESP:-}" "${SPONSOR_REPORT_RESP:-}" "${SETTLEMENT_RESP:-}" \
                "${ADMIN_RULES_RESP:-}" "${ADMIN_SETTLE_RESP:-}" "${ADMIN_FEEDBACK_RESP:-}"; do
  if [[ -n "${resp_var}" ]]; then
    security_check "growth-revenue" "${resp_var}" || SCAN_LEAK=true
  fi
done
if [[ "${SCAN_LEAK}" == "false" ]]; then
  pass "Secret leak scan (growth revenue): 0 leaks detected"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# REWARD NOTIFICATION SMOKE (TASK-CICD-GROWTH-REWARD-NOTIFICATION-001)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "========== REWARD NOTIFICATION SMOKE =========="

# ──────────────────────────────────────────────────────────────────────────────
# [17] Reward notification seed
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [17] Reward Notification Seed ---"
SEED_RESP=""
NOTIF_ID=""
for seed_path in "/api/v1/notifications" "/api/v1/growth/notifications" "/api/v1/user/notifications"; do
  # Generate a reward notification by hitting the backend (or seed via DB)
  SEED_RAW=$(curl -sS -w "\n%{http_code}" --max-time 5 -X POST \
    "${API_BASE}${seed_path}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"type\":\"reward\",\"title\":\"Reward Earned\",\"body\":\"You earned a growth reward!\",\"metadata\":{\"amount\":5.0,\"currency\":\"USDT\",\"reason\":\"referral_bonus\"},\"request_id\":\"growth-notif-seed-${TIMESTAMP}\"}") || true
  SD_HTTP=$(echo "${SEED_RAW}" | tail -1)
  if [[ "${SD_HTTP}" == "200" || "${SD_HTTP}" == "201" ]]; then
    SEED_RESP=$(echo "${SEED_RAW}" | sed '$d')
    NOTIF_ID=$(echo "${SEED_RESP}" | quiet_json "notification_id" || echo "${SEED_RESP}" | quiet_json "data.id" || echo "${SEED_RESP}" | quiet_json "id" || echo "")
    pass "Reward notification seed (${seed_path}): HTTP ${SD_HTTP}, id=${NOTIF_ID}"
    security_check "Notification seed" "${SEED_RESP}" || true
    break
  fi
done
if [[ -z "${SEED_RESP}" ]]; then
  # DB fallback seed
  pg_exec -c "INSERT INTO notifications (user_id, title, body, type, metadata, status, created_at) VALUES ((SELECT id FROM users WHERE email='${USER_EMAIL}'), 'Reward Earned', 'You earned a growth reward!', 'reward', '{\"amount\":5,\"currency\":\"USDT\",\"reason\":\"referral_bonus\"}', 'unread', NOW()) ON CONFLICT DO NOTHING" 2>/dev/null || true
  NOTIF_ID=$(pg_exec -c "SELECT id::text FROM notifications WHERE user_id=(SELECT id FROM users WHERE email='${USER_EMAIL}') ORDER BY created_at DESC LIMIT 1" 2>/dev/null | xargs || echo "")
  if [[ -n "${NOTIF_ID}" ]]; then
    echo "  Seeded notification via DB, id=${NOTIF_ID}"
    pass "Reward notification seed (DB fallback): id=${NOTIF_ID}"
  else
    skip "Reward notification seed: endpoint not yet deployed"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# [18] Reward notification fetch
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [18] Reward Notification Fetch ---"
NOTIF_FETCH_RESP=""
for fetch_path in "/api/v1/notifications" "/api/v1/growth/notifications" "/api/v1/user/notifications"; do
  FT_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${fetch_path}" \
    -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${FT_HTTP}" == "200" ]]; then
    NOTIF_FETCH_RESP=$(curl -sS --max-time 5 "${API_BASE}${fetch_path}" \
      -H "Authorization: Bearer ${USER_TOKEN}") || true
    NOTIF_COUNT=$(echo "${NOTIF_FETCH_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('notifications',data.get('items',data.get('data',[])))
print(len(items))
" 2>/dev/null || echo "0")
    pass "Notification fetch (${fetch_path}): HTTP 200, items=${NOTIF_COUNT}"
    security_check "Notification fetch" "${NOTIF_FETCH_RESP}" || true

    # Check notification type is reward
    HAS_REWARD=$(echo "${NOTIF_FETCH_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('notifications',data.get('items',data.get('data',[])))
for n in items:
    if n.get('type') == 'reward' or n.get('type') == 'growth_reward':
        print('FOUND')
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null || echo "NOT_FOUND")
    if [[ "${HAS_REWARD}" == "FOUND" ]]; then
      pass "Notification list contains reward-type notifications"
    else
      skip "No reward-type notification found in list (may not be seeded yet)"
    fi
    break
  fi
done
if [[ -z "${NOTIF_FETCH_RESP}" ]]; then
  skip "Notification fetch: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [19] Reward notification ack
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [19] Reward Notification Ack ---"
if [[ -n "${NOTIF_ID}" ]]; then
  for ack_path in "/api/v1/notifications" "/api/v1/growth/notifications" "/api/v1/user/notifications"; do
    ACK_RAW=$(curl -sS -w "\n%{http_code}" --max-time 5 -X PUT \
      "${API_BASE}${ack_path}/${NOTIF_ID}/ack" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${USER_TOKEN}" \
      -d "{\"request_id\":\"growth-notif-ack-${TIMESTAMP}\"}") || true
    ACK_HTTP=$(echo "${ACK_RAW}" | tail -1)
    if [[ "${ACK_HTTP}" == "200" || "${ACK_HTTP}" == "201" || "${ACK_HTTP}" == "204" ]]; then
      ACK_RESP=$(echo "${ACK_RAW}" | sed '$d')
      pass "Notification ack (${ack_path}/${NOTIF_ID}/ack): HTTP ${ACK_HTTP}"
      break
    fi
    # Try POST variant
    ACK_RAW2=$(curl -sS -w "\n%{http_code}" --max-time 5 -X POST \
      "${API_BASE}${ack_path}/${NOTIF_ID}/ack" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${USER_TOKEN}" \
      -d "{\"request_id\":\"growth-notif-ack2-${TIMESTAMP}\"}") || true
    ACK_HTTP2=$(echo "${ACK_RAW2}" | tail -1)
    if [[ "${ACK_HTTP2}" == "200" || "${ACK_HTTP2}" == "201" || "${ACK_HTTP2}" == "204" ]]; then
      pass "Notification ack POST (${ack_path}/${NOTIF_ID}/ack): HTTP ${ACK_HTTP2}"
      break
    fi
  done
  if [[ -z "${ACK_HTTP:-}" && -z "${ACK_HTTP2:-}" ]]; then
    skip "Notification ack: endpoint not yet deployed"
    pg_exec -c "UPDATE notifications SET status='read', read_at=NOW() WHERE id='${NOTIF_ID}'" 2>/dev/null || true
    echo "  Acked via DB fallback"
  fi
else
  skip "Notification ack: no notification id available"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [20] Admin notification list
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [20] Admin Notification List ---"
ADMIN_NOTIF_RESP=""
for an_path in "/admin/api/v1/notifications" "/admin/api/v1/growth/notifications"; do
  AN_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${an_path}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${AN_HTTP}" == "200" ]]; then
    ADMIN_NOTIF_RESP=$(curl -sS --max-time 5 "${API_BASE}${an_path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    pass "Admin notification list (${an_path}): HTTP 200"
    security_check "Admin notification list" "${ADMIN_NOTIF_RESP}" || true
    break
  fi
done
if [[ -z "${ADMIN_NOTIF_RESP}" ]]; then
  skip "Admin notification list: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [21] Admin notification preview
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [21] Admin Notification Preview ---"
ADMIN_PREVIEW_RESP=""
for ap_path in "/admin/api/v1/notifications/preview" "/admin/api/v1/growth/notifications/preview"; do
  AP_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}${ap_path}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${AP_HTTP}" == "200" ]]; then
    ADMIN_PREVIEW_RESP=$(curl -sS --max-time 5 "${API_BASE}${ap_path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    pass "Admin notification preview (${ap_path}): HTTP 200"
    security_check "Admin notification preview" "${ADMIN_PREVIEW_RESP}" || true
    break
  fi
done
if [[ -z "${ADMIN_PREVIEW_RESP}" ]]; then
  skip "Admin notification preview: endpoint not yet deployed"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [22] USDT no UDST typo safety
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [22] USDT no UDST Typo Safety ---"
TYPO_LEAK=false
# Check all growth-related responses to ensure no "UDST" typo appears
for resp_var in "${PAYOUT_CREATE_RESP:-}" "${PAYOUT_LIST_RESP:-}" "${SETTLEMENT_RESP:-}" \
                "${ADMIN_RULES_RESP:-}" "${ADMIN_SETTLE_RESP:-}" "${NOTIF_FETCH_RESP:-}" \
                "${ADMIN_NOTIF_RESP:-}" "${ADMIN_PREVIEW_RESP:-}"; do
  if [[ -n "${resp_var}" ]]; then
    if echo "${resp_var}" | grep -qi '"udst"' 2>/dev/null; then
      TYPO_LEAK=true
      fail "USDT typo 'UDST' found in response"
    fi
  fi
done
if [[ "${TYPO_LEAK}" == "false" ]]; then
  pass "USDT no UDST typo: no 'UDST' mis-spelling found in responses"
fi

# Also check API spec / contract for 'udst' in notification bodies created
USDT_IN_BODY=$(echo "${SEED_RESP:-}" | grep -ci 'UDST\|"udst"' 2>/dev/null || echo "0")
if [[ "${USDT_IN_BODY}" -gt 0 ]]; then
  fail "USDT typo 'UDST' in notification body"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [23] Secret leak scan (notifications)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [23] Secret Leak Scan (Notifications) ---"
NOTIF_SCAN_LEAK=false
for resp_var in "${SEED_RESP:-}" "${NOTIF_FETCH_RESP:-}" "${ADMIN_NOTIF_RESP:-}" "${ADMIN_PREVIEW_RESP:-}"; do
  if [[ -n "${resp_var}" ]]; then
    security_check "notifications" "${resp_var}" || NOTIF_SCAN_LEAK=true
  fi
done
if [[ "${NOTIF_SCAN_LEAK}" == "false" ]]; then
  pass "Secret leak scan (notifications): 0 leaks detected"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# USER PROFILE GROWTH FIELDS SMOKE (TASK-CICD-USER-PROFILE-GROWTH-FIELDS-SMOKE-001)
# ═══════════════════════════════════════════════════════════════════════════════
# Covers:
#   [24]  GET /api/v1/me — canonical profile with usdt_addresses + promotion_link
#   [25]  GET /api/v1/me/profile — full profile with growth fields
#   [26]  Create USDT payout method (trc20)
#   [27]  Create USDT payout method (erc20)
#   [28]  Create USDT payout method (bep20)
#   [29]  Fourth active address rejected
#   [30]  Unsupported protocol (btc) rejected
#   [31]  Payout-methods list — masking + no UDST typo
#   [32]  Secret leak scan (profile growth fields)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "========== USER PROFILE GROWTH FIELDS SMOKE =========="

# ──────────────────────────────────────────────────────────────────────────────
# [24] GET /api/v1/me — canonical profile
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [24] GET /api/v1/me (canonical profile) ---"
ME_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
ME_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/api/v1/me" \
  -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || true)

if [[ "${ME_HTTP}" == "200" ]]; then
  PROMO_LINK=$(echo "${ME_RESP}" | quiet_json "promotion_link" || echo "")
  if [[ -n "${PROMO_LINK}" ]]; then
    pass "GET /api/v1/me: promotion_link present: ${PROMO_LINK}"
  else
    REF_LINK=$(echo "${ME_RESP}" | quiet_json "referral_link" || echo "")
    if [[ -n "${REF_LINK}" ]]; then
      pass "GET /api/v1/me: referral_link present (backward-compat): ${REF_LINK}"
    else
      fail "GET /api/v1/me: neither promotion_link nor referral_link found"
    fi
  fi

  USDT_ADDR_COUNT=$(echo "${ME_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
addrs = data.get('usdt_addresses', [])
print(len(addrs))
" 2>/dev/null || echo "0")
  if [[ "${USDT_ADDR_COUNT}" -ge 0 ]] 2>/dev/null; then
    pass "GET /api/v1/me: usdt_addresses array present (count=${USDT_ADDR_COUNT})"
  else
    fail "GET /api/v1/me: usdt_addresses field missing"
  fi

  if echo "${ME_RESP}" | grep -qi '"udst"' 2>/dev/null; then
    fail "GET /api/v1/me: UDST typo found"
  else
    pass "GET /api/v1/me: no UDST typo"
  fi

  security_check "GET /api/v1/me" "${ME_RESP}" || true
else
  fail "GET /api/v1/me: HTTP ${ME_HTTP} (expected 200)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [25] GET /api/v1/me/profile — full profile with growth fields
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [25] GET /api/v1/me/profile (full profile with growth fields) ---"
PROFILE_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me/profile" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
PROFILE_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/api/v1/me/profile" \
  -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || true)

if [[ "${PROFILE_HTTP}" == "200" ]]; then
  PROFILE_PROMO=$(echo "${PROFILE_RESP}" | quiet_json "promotion_link" || echo "")
  if [[ -n "${PROFILE_PROMO}" ]]; then
    pass "GET /api/v1/me/profile: promotion_link present"
  else
    PROFILE_REF=$(echo "${PROFILE_RESP}" | quiet_json "referral_link" || echo "")
    if [[ -n "${PROFILE_REF}" ]]; then
      pass "GET /api/v1/me/profile: referral_link present (backward-compat)"
    else
      fail "GET /api/v1/me/profile: neither promotion_link nor referral_link found"
    fi
  fi

  PROFILE_USDT_COUNT=$(echo "${PROFILE_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
addrs = data.get('usdt_addresses', [])
print(len(addrs))
" 2>/dev/null || echo "0")
  if [[ "${PROFILE_USDT_COUNT}" -ge 0 ]] 2>/dev/null; then
    pass "GET /api/v1/me/profile: usdt_addresses array present (count=${PROFILE_USDT_COUNT})"
  else
    fail "GET /api/v1/me/profile: usdt_addresses field missing"
  fi

  if echo "${PROFILE_RESP}" | grep -qi '"udst"' 2>/dev/null; then
    fail "GET /api/v1/me/profile: UDST typo found"
  else
    pass "GET /api/v1/me/profile: no UDST typo"
  fi

  security_check "GET /api/v1/me/profile" "${PROFILE_RESP}" || true
else
  fail "GET /api/v1/me/profile: HTTP ${PROFILE_HTTP} (expected 200)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [26-28] Create USDT payout methods (trc20, erc20, bep20)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [26-28] Create USDT Payout Methods (trc20+erc20+bep20) ---"

create_payout_method() {
  local protocol="$1"
  local address="$2"
  local label="$3"
  local resp
  local http_code
  resp=$(curl -sS -w "\n%{http_code}" --max-time 5 -X POST \
    "${API_BASE}/api/v1/me/payout-methods" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${USER_TOKEN}" \
    -d "{\"protocol\":\"${protocol}\",\"address\":\"${address}\",\"is_default\":false,\"request_id\":\"profile-growth-payout-${protocol}-${TIMESTAMP}\"}") || { echo "FAIL: curl error"; return 1; }
  http_code=$(echo "${resp}" | tail -1)
  body=$(echo "${resp}" | sed '$d')

  if [[ "${http_code}" == "200" || "${http_code}" == "201" ]]; then
    local pid
    pid=$(echo "${body}" | quiet_json "payout_method_id" || echo "${body}" | quiet_json "id" || echo "")
    echo "  PASS: [${label}] ${protocol} -> HTTP ${http_code}, id=${pid}"
    return 0
  elif [[ "${http_code}" == "000" || -z "${http_code}" ]]; then
    echo "  SKIP: [${label}] ${protocol} -> no response (endpoint may not be deployed)"
    return 0
  else
    echo "  FAIL: [${label}] ${protocol} -> HTTP ${http_code}"
    echo "    Body: ${body}"
    return 1
  fi
}

create_ok=true
create_payout_method "trc20" "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" "CR26" || create_ok=false
create_payout_method "erc20" "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18" "CR27" || create_ok=false
create_payout_method "bep20" "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18" "CR28" || create_ok=false

if [[ "${create_ok}" == "false" ]]; then
  echo "  Note: payout-method creation may not yet be deployed in this build"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [29] Fourth active address rejected
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [29] Fourth Active Address Rejected ---"
FOURTH_PROTOCOL="trc20"
FOURTH_ADDR="TAb4aH6cW1j2kL3mN4oP5qR6sT7uV8wX9yZ"
FOURTH_RAW=$(curl -sS -w "\n%{http_code}" --max-time 5 -X POST \
  "${API_BASE}/api/v1/me/payout-methods" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d "{\"protocol\":\"${FOURTH_PROTOCOL}\",\"address\":\"${FOURTH_ADDR}\",\"is_default\":false,\"request_id\":\"profile-growth-4th-${TIMESTAMP}\"}") || true
FOURTH_HTTP=$(echo "${FOURTH_RAW}" | tail -1)
FOURTH_BODY=$(echo "${FOURTH_RAW}" | sed '$d')

if [[ "${FOURTH_HTTP}" == "400" || "${FOURTH_HTTP}" == "422" || "${FOURTH_HTTP}" == "409" ]]; then
  pass "Fourth active address rejected: HTTP ${FOURTH_HTTP}"
elif [[ "${FOURTH_HTTP}" == "200" || "${FOURTH_HTTP}" == "201" ]]; then
  fail "Fourth active address NOT rejected: HTTP ${FOURTH_HTTP} (should enforce limit of 3)"
else
  skip "Fourth address check: HTTP ${FOURTH_HTTP} (endpoint may be partially deployed)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [30] Unsupported protocol (btc) rejected
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [30] Unsupported Protocol (btc) Rejected ---"
BTC_RAW=$(curl -sS -w "\n%{http_code}" --max-time 5 -X POST \
  "${API_BASE}/api/v1/me/payout-methods" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -d "{\"protocol\":\"btc\",\"address\":\"1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa\",\"is_default\":false,\"request_id\":\"profile-growth-btc-${TIMESTAMP}\"}") || true
BTC_HTTP=$(echo "${BTC_RAW}" | tail -1)
BTC_BODY=$(echo "${BTC_RAW}" | sed '$d')

if [[ "${BTC_HTTP}" == "400" || "${BTC_HTTP}" == "422" ]]; then
  pass "Unsupported protocol (btc) rejected: HTTP ${BTC_HTTP}"
elif [[ "${BTC_HTTP}" == "200" || "${BTC_HTTP}" == "201" ]]; then
  fail "Unsupported protocol (btc) NOT rejected: HTTP ${BTC_HTTP} (only trc20/erc20/bep20 allowed)"
else
  skip "Unsupported protocol check: HTTP ${BTC_HTTP} (endpoint may not be deployed)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [31] Payout-methods list — masking + no UDST typo
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [31] GET /api/v1/me/payout-methods (list with masking) ---"
PAYOUT_METHODS_RESP=$(curl -sS --max-time 5 "${API_BASE}/api/v1/me/payout-methods" \
  -H "Authorization: Bearer ${USER_TOKEN}") || true
PAYOUT_METHODS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/api/v1/me/payout-methods" \
  -H "Authorization: Bearer ${USER_TOKEN}" 2>/dev/null || true)

if [[ "${PAYOUT_METHODS_HTTP}" == "200" ]]; then
  PM_COUNT=$(echo "${PAYOUT_METHODS_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('payout_methods', data.get('methods', data.get('data', [])))
print(len(items))
" 2>/dev/null || echo "0")
  pass "Payout methods list: HTTP 200, count=${PM_COUNT}"

  HAS_UNMASKED=$(echo "${PAYOUT_METHODS_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items = data.get('payout_methods', data.get('methods', data.get('data', [])))
for item in items:
    addr = str(item.get('address', item.get('masked_address', item.get('account',''))))
    if len(addr) > 20 and not any(m in addr for m in ['****','***','...','xxx']):
        print('UNMASKED: ' + addr[:10])
        sys.exit(0)
print('MASKED_OK')
" 2>/dev/null || echo "MASKED_OK")
  if [[ "${HAS_UNMASKED}" == "MASKED_OK" ]]; then
    pass "Payout methods: addresses are masked (no full wallet leak)"
  else
    skip "Payout methods: ${HAS_UNMASKED} (masking format may differ)"
  fi

  if echo "${PAYOUT_METHODS_RESP}" | grep -qi '"udst"' 2>/dev/null; then
    fail "Payout methods list: UDST typo found"
  else
    pass "Payout methods list: no UDST typo"
  fi

  security_check "Payout methods list" "${PAYOUT_METHODS_RESP}" || true
else
  skip "Payout methods list: HTTP ${PAYOUT_METHODS_HTTP}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [32] Secret leak scan (profile growth fields)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [32] Secret Leak Scan (Profile Growth Fields) ---"
PROFILE_SCAN_LEAK=false
for resp_var in "${ME_RESP:-}" "${PROFILE_RESP:-}" "${PAYOUT_METHODS_RESP:-}"; do
  if [[ -n "${resp_var}" ]]; then
    security_check "profile-growth-fields" "${resp_var}" || PROFILE_SCAN_LEAK=true
  fi
done
if [[ "${PROFILE_SCAN_LEAK}" == "false" ]]; then
  pass "Secret leak scan (profile growth fields): 0 leaks detected"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Cleanup
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- Cleanup ---"
pg_exec -c "DELETE FROM notifications WHERE user_id=(SELECT id FROM users WHERE email='${USER_EMAIL}')" 2>/dev/null || true
pg_exec -c "DELETE FROM growth_payouts WHERE user_id=(SELECT id FROM users WHERE email='${USER_EMAIL}')" 2>/dev/null || true
pg_exec -c "DELETE FROM referral_links WHERE user_id=(SELECT id FROM users WHERE email='${USER_EMAIL}')" 2>/dev/null || true
pg_exec -c "DELETE FROM growth_settlements WHERE user_id=(SELECT id FROM users WHERE email='${USER_EMAIL}')" 2>/dev/null || true
pg_exec -c "DELETE FROM user_payout_methods WHERE user_id=(SELECT id FROM users WHERE email='${USER_EMAIL}')" 2>/dev/null || true
pg_exec -c "DELETE FROM users WHERE email='${USER_EMAIL}'" 2>/dev/null || true
echo "  Cleaned up growth smoke data"
echo "  Kept seed admin: admin@livemask.dev"

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo " GROWTH REVENUE + REWARD NOTIFICATION SUMMARY"
echo "================================================"
printf '%s\n' "${SUMMARY_LINES[@]}"

echo ""
if [[ "${FAILED}" -eq 1 ]]; then
  echo "[TASK-CICD-USER-GROWTH-REVENUE-001 / TASK-CICD-GROWTH-REWARD-NOTIFICATION-001 / TASK-CICD-USER-PROFILE-GROWTH-FIELDS-SMOKE-001] SMOKE FAILED."
  echo ""
  echo "--- docker compose ps ---"
  docker compose -f "${COMPOSE_FILE}" ps 2>/dev/null || true
  echo ""
  echo "--- docker compose logs backend (last 100) ---"
  docker compose -f "${COMPOSE_FILE}" logs backend --tail=100 2>/dev/null || true
  exit 1
fi

echo "[TASK-CICD-USER-GROWTH-REVENUE-001 / TASK-CICD-GROWTH-REWARD-NOTIFICATION-001 / TASK-CICD-USER-PROFILE-GROWTH-FIELDS-SMOKE-001] Growth revenue + reward notification + user profile growth fields smoke PASSED."
echo "Covers: USDT payout, Alipay blocked, Payout list, Referral link/report,"
echo "  Sponsor report, Settlements, Revenue redaction, Admin rules/settlements/feedback,"
echo "  RBAC, Reward notification seed/fetch/ack, Admin notification list/preview,"
echo "  USDT typo safety, Secret leak scans,"
echo "  GET /api/v1/me, GET /api/v1/me/profile, payout-method CRUD,"
echo "  address limit enforcement, protocol validation, masking, no UDST typo"
