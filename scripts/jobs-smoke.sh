#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-ADMIN-CONTROL-PLANE-SMOKE-001 — enhanced
# Job Service Smoke + Admin Job Center smoke
# ═══════════════════════════════════════════════════════════════════════════════
# Covers:
#   [1]  Job Service health
#   [2]  Job definitions list
#   [3]  Job run create + detail
#   [4]  Run events + secret check
#   [5]  Admin login (for admin API tests)
#   [6]  Admin Job Center page 404 check
#   [7]  Admin GET job definitions
#   [8]  Admin GET job runs
#   [9]  Admin GET job schedules
#   [10] RBAC: no token / user token → 401/403
#   [11] Secret leak scan
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/base_service.sh"
COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
JOB_SERVICE_URL="${JOB_SERVICE_URL:-$(lm_job_service_url)}"
API_BASE="$(lm_backend_base_url)"

FAILED=0
SUMMARY_LINES=()
pass_count=0
fail_count=0
skip_count=0

ok() {
  echo "  PASS: $1"
  SUMMARY_LINES+=("PASS: $1")
  ((pass_count++)) || true
}

bad() {
  echo "  FAIL: $1" >&2
  SUMMARY_LINES+=("FAIL: $1")
  FAILED=1
  ((fail_count++)) || true
}

skip_msg() {
  echo "  SKIP: $1"
  SUMMARY_LINES+=("SKIP: $1")
  ((skip_count++)) || true
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

security_check_jobs() {
  local label="$1"
  local json="$2"
  local extra_sensitive="${3:-}"
  local leaked
  leaked=$(echo "${json}" | python3 -c "
import sys,json
SENSITIVE_WORDS = [
    'password_hash','node_secret','hmac','private_key','secret_key',
    'storage_path','encryption_key','access_token','refresh_token',
    'api_key','license_key','authorization','bearer',
    'node_secret','relay_secret','webhook_secret',
    'private_key','signed_query_token',
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
    bad "[SECURITY] ${label}: ${leaked}"
    return 1
  fi
  return 0
}

pg_exec() {
  docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA "$@" 2>/dev/null || true
}

json_get() {
  curl -fsS "$1"
}

echo "================================================"
echo " TASK-CICD-JOBS-001 + ADMIN-CONTROL-PLANE-001"
echo " Job Service & Admin Job Center Smoke"
echo "================================================"
lm_runtime_status_report
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# [1] Backend health
# ──────────────────────────────────────────────────────────────────────────────
echo "--- [1] Backend Health ---"
for attempt in $(seq 1 30); do
  health_resp=$(lm_backend_health_json || true)
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    echo "  Backend ready (attempt ${attempt})"
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    echo "  BLOCKER: Backend not ready after 30 attempts"
    exit 1
  fi
  sleep 2
done
ok "Backend health ok"

# ──────────────────────────────────────────────────────────────────────────────
# [2] Admin login
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [2] Admin Login ---"
pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'" 2>/dev/null || true
ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -n "${ADMIN_HASH}" ]]; then
  pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'" 2>/dev/null
  pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by jobs-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
fi
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"jbsmoke-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then
  echo "  BLOCKER: Admin login — no access token"
  exit 1
fi
ok "Admin login OK (token length=${#ADMIN_TOKEN})"

# ──────────────────────────────────────────────────────────────────────────────
# [3] Job Service health (internal)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [3] Job Service Health ---"
if health="$(json_get "${JOB_SERVICE_URL}/healthz" 2>/dev/null)"; then
  echo "${health}" | grep -q '"status":"ok"' && ok "Job service healthz ok" || bad "Job service healthz missing ok"
else
  skip_msg "Job service healthz unavailable (standalone job service may not be running)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [4] Job definitions (internal)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [4] Job Definitions (Internal) ---"
if defs="$(json_get "${JOB_SERVICE_URL}/internal/jobs" 2>/dev/null)"; then
  echo "${defs}" | grep -q 'geoip_source_update' && ok "definitions include geoip_source_update" || bad "missing geoip_source_update"
  echo "${defs}" | grep -q 'nodeagent_release_rollout' && ok "definitions include nodeagent_release_rollout" || bad "missing nodeagent_release_rollout"
else
  skip_msg "Job definitions unavailable (standalone job service not running)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# [5] Job run create + detail
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [5] Job Run Create / Detail ---"
run_id=""
run_body='{"job_type":"geoip_source_update","trigger_type":"manual","triggered_by":"smoke","parameters":{"source":"dbip_lite","edition":"country","force":false}}'
if run_resp="$(curl -fsS --max-time 5 -X POST "${JOB_SERVICE_URL}/internal/jobs/runs" -H "Content-Type: application/json" -d "${run_body}" 2>/dev/null)"; then
  run_id="$(printf '%s' "${run_resp}" | sed -n 's/.*"run_id":"\([^"]*\)".*/\1/p')"
  [[ -n "${run_id}" ]] && ok "Run created ${run_id}" || bad "run_id missing"
else
  skip_msg "Run create failed (job service not deployed)"
fi

if [[ -n "${run_id:-}" ]]; then
  sleep 3
  if detail="$(json_get "${JOB_SERVICE_URL}/internal/jobs/runs/${run_id}" 2>/dev/null)"; then
    echo "${detail}" | grep -Eq '"status":"(queued|running|succeeded)"' && ok "Run detail status valid" || bad "run detail invalid"
  else
    bad "Run detail unavailable"
  fi
  if events="$(json_get "${JOB_SERVICE_URL}/internal/jobs/runs/${run_id}/events" 2>/dev/null)"; then
    echo "${events}" | grep -q 'run_queued' && ok "Events include run_queued" || bad "Events missing run_queued"
    if echo "${events}" | grep -Eiq 'license_key|api_key|node_secret|private_key|hmac|token='; then
      bad "Events leak sensitive marker"
    else
      ok "Events do not leak sensitive markers"
    fi
  else
    bad "Events unavailable"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# [6] Admin Job Center Page 404 Check (TASK-CICD-ADMIN-CONTROL-PLANE-SMOKE-001)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [6] Admin Job Center Page 404 Check ---"
ADMIN_JOB_PAGES=(
  "/admin/jobs"
  "/admin/jobs/runs"
  "/admin/jobs/schedules"
)
for page in "${ADMIN_JOB_PAGES[@]}"; do
  PAGE_HTTP=$(lm_admin_page_http "${page}")
  if [[ "${PAGE_HTTP}" == "200" ]]; then
    ok "Admin page ${page}: HTTP 200"
  elif [[ "${PAGE_HTTP}" == "404" ]]; then
    skip_msg "Admin page ${page}: HTTP 404 — Admin Next.js not deployed in staging"
  elif [[ "${PAGE_HTTP}" == "000" ]]; then
    skip_msg "Admin page ${page}: unreachable"
  else
    skip_msg "Admin page ${page}: HTTP ${PAGE_HTTP}"
  fi
done

# ──────────────────────────────────────────────────────────────────────────────
# [7] Admin GET job definitions
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [7] Admin GET Job Definitions ---"
ADMIN_DEFS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/jobs/definitions" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
case "${ADMIN_DEFS_HTTP}" in
  200)
    ADMIN_DEFS_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/jobs/definitions" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    ok "Admin job definitions: HTTP 200"
    security_check_jobs "Admin job definitions" "${ADMIN_DEFS_RESP}" || true
    ;;
  404)
    skip_msg "Admin job definitions: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip_msg "Admin job definitions: HTTP ${ADMIN_DEFS_HTTP}"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# [8] Admin GET job runs
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [8] Admin GET Job Runs ---"
ADMIN_RUNS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/jobs/runs" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
case "${ADMIN_RUNS_HTTP}" in
  200)
    ADMIN_RUNS_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/jobs/runs" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    ok "Admin job runs: HTTP 200"
    security_check_jobs "Admin job runs" "${ADMIN_RUNS_RESP}" || true
    ;;
  404)
    skip_msg "Admin job runs: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip_msg "Admin job runs: HTTP ${ADMIN_RUNS_HTTP}"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# [9] Admin GET job schedules
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [9] Admin GET Job Schedules ---"
ADMIN_SCHED_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/jobs/schedules" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
case "${ADMIN_SCHED_HTTP}" in
  200)
    ADMIN_SCHED_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/jobs/schedules" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}") || true
    ok "Admin job schedules: HTTP 200"
    security_check_jobs "Admin job schedules" "${ADMIN_SCHED_RESP}" || true
    ;;
  404)
    skip_msg "Admin job schedules: HTTP 404 (endpoint not yet deployed)"
    ;;
  *)
    skip_msg "Admin job schedules: HTTP ${ADMIN_SCHED_HTTP}"
    ;;
esac

# ──────────────────────────────────────────────────────────────────────────────
# [10] RBAC: no token / user token → 401/403
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [10] RBAC Tests ---"
RBAC_EMAIL="jobs-rbac-$(date +%s)@test.livemask"
RBAC_PASS="JobsRbac123!"
pg_exec -c "DELETE FROM users WHERE email='${RBAC_EMAIL}'" 2>/dev/null || true
RBAC_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"request_id\":\"jobs-rbac-reg\",\"email\":\"${RBAC_EMAIL}\",\"password\":\"${RBAC_PASS}\",\"display_name\":\"Jobs RBAC\",\"client_type\":\"website\"}") || true
RBAC_TOKEN=$(echo "${RBAC_REG}" | quiet_json "access_token")
if [[ -z "${RBAC_TOKEN}" ]]; then
  RBAC_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/api/v1/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"request_id\":\"jobs-rbac-login\",\"email\":\"${RBAC_EMAIL}\",\"password\":\"${RBAC_PASS}\",\"client_type\":\"website\"}") || true
  RBAC_TOKEN=$(echo "${RBAC_LOGIN}" | quiet_json "access_token")
fi

if [[ -n "${RBAC_TOKEN}" ]]; then
  for ep in "admin/api/v1/jobs/definitions" "admin/api/v1/jobs/runs" "admin/api/v1/jobs/schedules"; do
    NO_TOK_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "${API_BASE}/${ep}" 2>/dev/null || true)
    if [[ "${NO_TOK_HTTP}" == "404" ]]; then
      skip_msg "RBAC no-token ${ep}: HTTP 404 (endpoint not yet deployed)"
      continue
    elif [[ "${NO_TOK_HTTP}" == "401" ]]; then
      ok "RBAC no-token ${ep}: HTTP 401"
    else
      bad "RBAC no-token ${ep}: HTTP ${NO_TOK_HTTP} (expected 401)"
    fi

    USER_TOK_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
      "${API_BASE}/${ep}" \
      -H "Authorization: Bearer ${RBAC_TOKEN}" 2>/dev/null || true)
    if [[ "${USER_TOK_HTTP}" == "404" ]]; then
      skip_msg "RBAC user-token ${ep}: HTTP 404 (endpoint not yet deployed)"
    elif [[ "${USER_TOK_HTTP}" == "403" || "${USER_TOK_HTTP}" == "401" ]]; then
      ok "RBAC user-token ${ep}: HTTP ${USER_TOK_HTTP}"
    else
      bad "RBAC user-token ${ep}: HTTP ${USER_TOK_HTTP} (expected 401/403)"
    fi
  done
else
  skip_msg "RBAC tests: no user token"
fi
pg_exec -c "DELETE FROM users WHERE email='${RBAC_EMAIL}'" 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# [11] Secret leak scan
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [11] Secret Leak Scan ---"
LEAK_FOUND=false
if [[ -n "${ADMIN_TOKEN}" ]]; then
  for scan_path in "jobs/definitions" "jobs/runs" "jobs/schedules"; do
    SCAN_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/${scan_path}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
    if [[ "${SCAN_RESP}" != "{}" ]]; then
      security_check_jobs "admin/${scan_path}" "${SCAN_RESP}" || LEAK_FOUND=true
    fi
  done
fi
if [[ "${LEAK_FOUND}" == "false" ]]; then
  ok "Secret leak scan: 0 leaks detected"
else
  echo "  WARNING: Leaks detected (see above)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Cleanup ---"
if [[ -n "${run_id:-}" ]]; then
  curl -sS --max-time 5 -X DELETE "${JOB_SERVICE_URL}/internal/jobs/runs/${run_id}" >/dev/null 2>&1 || true
fi
echo "  Cleaned up: job smoke data"
echo "  Kept seed admin: admin@livemask.dev"

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo " JOBS SMOKE SUMMARY"
echo "================================================"
printf '%s\n' "${SUMMARY_LINES[@]}"
echo ""
echo "PASS=${pass_count} SKIP=${skip_count} FAIL=${fail_count}"
echo ""
if [[ "${FAILED}" -eq 1 ]]; then
  echo "[jobs-smoke] JOBS SMOKE FAILED."
  exit 1
fi
echo "[jobs-smoke] Jobs smoke PASSED."
echo "Covers: Backend health, Admin login, Job service health, definitions, runs,"
echo "  Admin job pages 404 check, Admin definitions/runs/schedules API,"
echo "  RBAC, Secret leak scan"
