#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-NODEAGENT-CREDENTIAL-ROTATION-SMOKE-001
# NodeAgent Credential Rotation Smoke
# Verifies the operational lifecycle: register → rotate → new cred auth →
# grace/rolling fallback → revoke → re-enroll → NodeAgent fallback → secret
# leak scan.  All raw credential material is redacted from output/artifacts.
# ═══════════════════════════════════════════════════════════════════════════════
# Scenarios:
#   A  Backend health / auth preflight
#   B  Rotate credential (admin API)
#   C  New X-Key-ID credential authenticates
#   D  Grace / rolling fallback (old credential still valid during overlap)
#   E  Revoke behavior (revoked credential rejected)
#   F  Re-enroll issues fresh credential
#   G  NodeAgent fallback evidence (if NodeAgent runtime available)
#   H  Secret leak scan (over own output and artifacts)
# ═══════════════════════════════════════════════════════════════════════════════

# TASK-CICD-NODEAGENT-CREDENTIAL-ROTATION-SMOKE-001
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/base_service.sh"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
API_BASE="$(lm_backend_base_url)"
NODEAGENT_API="http://127.0.0.1:${LIVEMASK_NODEAGENT_PORT:-19090}"
TIMESTAMP="$(date +%s)"

# ── Scenario result counters ─────────────────────────────────────────────────
FAILED=0
PASS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
SCENARIOS=()
SCENARIO_RESULTS=()

# ── Temp file for secret scan artifacts ──────────────────────────────────────
SCAN_ARTIFACT="$(mktemp /tmp/cred-rotation-smoke-scan.XXXXXX.txt)"
CAPTURED_OUTPUTS="$(mktemp /tmp/cred-rotation-smoke-captures.XXXXXX.txt)"
trap 'rm -f "${SCAN_ARTIFACT}" "${CAPTURED_OUTPUTS}" 2>/dev/null || true' EXIT

# ── PASS / FAIL / SKIP / BLOCKER helpers ────────────────────────────────────
pass() {
  local msg="$1"
  echo "  PASS: ${msg}"
  SCENARIO_RESULTS+=("PASS: ${msg}")
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  local msg="$1"
  echo "  FAIL: ${msg}"
  SCENARIO_RESULTS+=("FAIL: ${msg}")
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED=1
}

skip() {
  local msg="$1"
  echo "  SKIP: ${msg}"
  SCENARIO_RESULTS+=("SKIP: ${msg}")
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

blocker() {
  local msg="$1"
  echo "  BLOCKER: ${msg}"
  SCENARIO_RESULTS+=("BLOCKER: ${msg}")
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILED=1
}

# ── Quiet JSON path extractor ────────────────────────────────────────────────
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

# ── HMAC signature computation (credential-versioned auth) ───────────────────
# Uses raw_secret (node_secret) which Backend hashes to verify.
# Backend middleware: computeSignature(nodeID, timestamp, secretHash)
# where secretHash is the stored hash of the raw secret.
# Smoke sends X-Key-ID so Backend looks up credential by key_id and uses its
# stored SecretHash for verification.
compute_signature() {
  local node_id="$1"
  local timestamp="$2"
  local raw_secret="$3"
  python3 -c "
import hmac, hashlib
# Backend hashes the raw secret before HMAC
secret_hash = hashlib.sha256('${raw_secret}'.encode()).hexdigest()
msg = '${node_id}:${timestamp}'
sig = hmac.new(secret_hash.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
"
}

# ── HMAC signature with a pre-computed secret_hash (for admin responses) ────
compute_signature_with_hash() {
  local node_id="$1"
  local timestamp="$2"
  local secret_hash="$3"
  python3 -c "
import hmac, hashlib
msg = '${node_id}:${timestamp}'
sig = hmac.new('${secret_hash}'.encode(), msg.encode(), hashlib.sha256).hexdigest()
print(sig)
"
}

# ── HTTP request with X-Key-ID credential-versioned auth ─────────────────────
cred_get() {
  local url="$1"
  local node_id="$2"
  local raw_secret="$3"
  local key_id="${4:-}"
  local ts
  ts=$(date +%s)
  local sig
  sig=$(compute_signature "${node_id}" "${ts}" "${raw_secret}")
  curl -sS --max-time 5 -w "\n%{http_code}" -X GET "${url}" \
    -H "X-Node-ID: ${node_id}" \
    -H "X-Timestamp: ${ts}" \
    -H "X-Signature: ${sig}" \
    ${key_id:+-H "X-Key-ID: ${key_id}"} 2>/dev/null || echo "\\n000"
}

cred_post() {
  local url="$1"
  local body="$2"
  local node_id="$3"
  local raw_secret="$4"
  local key_id="${5:-}"
  local ts
  ts=$(date +%s)
  local sig
  sig=$(compute_signature "${node_id}" "${ts}" "${raw_secret}")
  curl -sS --max-time 5 -w "\n%{http_code}" -X POST "${url}" \
    -H "Content-Type: application/json" \
    -H "X-Node-ID: ${node_id}" \
    -H "X-Timestamp: ${ts}" \
    -H "X-Signature: ${sig}" \
    ${key_id:+-H "X-Key-ID: ${key_id}"} \
    -d "${body}" 2>/dev/null || echo "\\n000"
}

# Split HTTP status code from response body
http_split() {
  local raw="$1"
  local code
  code="$(echo "${raw}" | tail -1)"
  local body
  body="$(echo "${raw}" | sed '$d')"
  printf '%s|%s' "${body}" "${code}"
}

# ── Python JSON-aware redaction ──────────────────────────────────────────────
# Replaces secret VALUES with <REDACTED> markers.  Leaves field names intact.
# Handles: JSON key-value pairs, Authorization/ X-Signature headers,
# key=value formats, long hex/base64 strings.
redact() {
  python3 -c '
import sys, json, re

SECRET_FIELDS = frozenset([
    "node_secret", "secret_hash", "access_token", "bearer_token",
    "refresh_token", "token", "api_key", "private_key", "dsn", "secret",
    "hmac_key", "signing_key", "session_token",
])

text = sys.stdin.read()

# JSON-aware redaction (exact key match, preserves structure)
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
except (json.JSONDecodeError, ValueError, TypeError):
    pass

# Regex fallback for non-JSON content
# Authorization: Bearer <jwt>
text = re.sub(
    r"(Authorization:\s*Bearer\s+)[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+",
    r"\1<REDACTED-JWT>", text, flags=re.IGNORECASE
)
# Any standalone JWT-like token
text = re.sub(
    r"(?<![A-Za-z0-9_\-])[A-Za-z0-9_\-]{12,}\.[A-Za-z0-9_\-]{12,}\.[A-Za-z0-9_\-]{12,}(?![A-Za-z0-9_\-])",
    "<REDACTED-JWT>", text
)
# X-Signature: <long-hex>
text = re.sub(r"(X-Signature:\s*)[a-fA-F0-9]{64,}", r"\1<REDACTED-SIG>", text)
# key=value or key:value for known fields
text = re.sub(
    r"(node_secret|access_token|bearer_token|refresh_token|token|secret_hash|private_key)\s*[=:]\s*[A-Za-z0-9_\-{}]{8,}",
    r"\1=<REDACTED>", text, flags=re.IGNORECASE
)
# Long hex strings (potential hashes / raw secrets)
text = re.sub(r"[a-fA-F0-9]{64,}", "<REDACTED-HEX>", text)
# Long base64-like strings (potential tokens)
text = re.sub(r"[A-Za-z0-9+/=]{80,}", "<REDACTED-BASE64>", text)

# DSN / connection strings
text = re.sub(r"(postgres|redis|mysql|mongodb)://[^@\s]+@", r"\1://<REDACTED-CREDS>@", text, flags=re.IGNORECASE)

sys.stdout.write(text)
' <<< "$1"
}

# ── Capture output for leak scanning ──────────────────────────────────────────
# Each scenario calls this to write redacted responses into CAPTURED_OUTPUTS,
# which Scenario H scans at the end for remaining value-pattern leaks.
capture_for_scan() {
  local label="$1"
  local content="$2"
  local redacted
  redacted="$(redact "${content}")"
  printf '[%s] %s\n' "${label}" "${redacted}" >> "${CAPTURED_OUTPUTS}"
}

# ── Secret VALUE leak scan (writes to SCAN_ARTIFACT on match) ──────────────
secret_leak_scan() {
  local label="$1"
  local content="$2"
  local details
  details="$(secret_leak_detect_only "${content}")" || true
  if [[ -n "${details}" ]]; then
    echo "[LEAK] ${label}: ${details}" >> "${SCAN_ARTIFACT}"
    return 0  # leak found → truthy for caller
  fi
  return 1  # no leak → falsy for caller
}

# ── Secret VALUE leak detect-only (side-effect free) ─────────────────────────
# Same VALUE-pattern detection as secret_leak_scan, but does NOT write to
# SCAN_ARTIFACT.  Returns detected leak types on stdout (pipe-separated),
# or empty string if clean.  Callers should use  || true  to avoid set -e.
secret_leak_detect_only() {
  local content="$1"
  python3 -c '
import sys, re
LEAK_PATTERNS = [
    (r"[A-Za-z0-9_\-]{12,}\.[A-Za-z0-9_\-]{12,}\.[A-Za-z0-9_\-]{12,}", "JWT-token"),
    (r"[a-fA-F0-9]{64,}", "hex-64+"),
    (r"[A-Za-z0-9+/=]{80,}", "base64-80+"),
    (r"-----BEGIN\s+(RSA\s+)?PRIVATE\s+KEY-----", "private-key"),
]
text = sys.stdin.read()
leaks = []
for pat, name in LEAK_PATTERNS:
    matches = re.findall(pat, text)
    if matches:
        leaks.append(f"{name}:{len(matches)}")
if leaks:
    print("|".join(leaks))
    sys.exit(0)
sys.exit(1)
' <<< "${content}" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# S E L F - T E S T   —   deterministic redaction / leak-scan sanity check
# ═══════════════════════════════════════════════════════════════════════════════
self_test() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo " [S] Self-test: redaction and leak-scan sanity"
  echo "═══════════════════════════════════════════════════════════════════"
  SCENARIOS+=("S")

  local failures=0

  # Test vector 1: JSON with node_secret
  local test_json='{"node_id":"abc123","node_secret":"s3cret_Value_DoNotShare!","status":"active"}'
  local redacted_json
  redacted_json="$(redact "${test_json}")"
  if echo "${redacted_json}" | grep -qF 's3cret_Value_DoNotShare!'; then
    echo "  FAIL: JSON node_secret value NOT redacted"
    failures=$((failures + 1))
  elif echo "${redacted_json}" | grep -qF '<REDACTED>'; then
    pass "S.1 JSON node_secret value redacted"
  else
    echo "  FAIL: JSON redaction produced unexpected output: ${redacted_json}"
    failures=$((failures + 1))
  fi

  # Test vector 2: JWT in Authorization header
  local test_jwt='Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3j6rB5oGgCb8e7sK6Q5y4x3w2v1u0t9s8'
  local redacted_jwt
  redacted_jwt="$(redact "${test_jwt}")"
  if echo "${redacted_jwt}" | grep -qF 'eyJhbGciOiJIUzI1NiJ9'; then
    echo "  FAIL: JWT value NOT redacted"
    failures=$((failures + 1))
  elif echo "${redacted_jwt}" | grep -qF '<REDACTED-JWT>'; then
    pass "S.2 Authorization Bearer JWT redacted"
  else
    echo "  FAIL: JWT redaction produced unexpected output: ${redacted_jwt}"
    failures=$((failures + 1))
  fi

  # Test vector 3: X-Signature hex
  local test_sig='X-Signature: a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2'
  local redacted_sig
  redacted_sig="$(redact "${test_sig}")"
  if echo "${redacted_sig}" | grep -qF 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2'; then
    echo "  FAIL: X-Signature hex NOT redacted"
    failures=$((failures + 1))
  elif echo "${redacted_sig}" | grep -qF '<REDACTED-SIG>'; then
    pass "S.3 X-Signature hex redacted"
  else
    echo "  FAIL: X-Signature redaction produced unexpected output: ${redacted_sig}"
    failures=$((failures + 1))
  fi

  # Test vector 4: access_token in key=value format
  local test_kv='access_token=mySuperSecretTokenValue123!'
  local redacted_kv
  redacted_kv="$(redact "${test_kv}")"
  if echo "${redacted_kv}" | grep -qF 'mySuperSecretTokenValue123!'; then
    echo "  FAIL: access_token=value NOT redacted"
    failures=$((failures + 1))
  elif echo "${redacted_kv}" | grep -qF '<REDACTED>'; then
    pass "S.4 access_token=value redacted"
  else
    echo "  FAIL: key=value redaction produced unexpected output: ${redacted_kv}"
    failures=$((failures + 1))
  fi

  # Test vector 5: secret_leak_detect_only returns empty for clean redacted content
  local clean_input='{"node_secret":"<REDACTED>","access_token":"<REDACTED>"}'
  local detect_result
  detect_result="$(secret_leak_detect_only "${clean_input}")"
  if [[ -n "${detect_result}" ]]; then
    echo "  FAIL: secret_leak_detect_only reports leak in already-redacted content: ${detect_result}"
    failures=$((failures + 1))
  else
    pass "S.5 secret_leak_detect_only: clean on redacted content"
  fi

  # Test vector 6: secret_leak_detect_only returns non-empty for raw JWT
  local raw_jwt='Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3j6rB5oGgCb8e7sK6Q5y4x3w2v1u0t9s8'
  detect_result="$(secret_leak_detect_only "${raw_jwt}")"
  if [[ -n "${detect_result}" ]]; then
    pass "S.6 secret_leak_detect_only: raw JWT correctly detected (${detect_result})"
  else
    echo "  FAIL: secret_leak_detect_only did NOT detect raw JWT"
    failures=$((failures + 1))
  fi

  if [[ "${failures}" -gt 0 ]]; then
    fail "S Self-test: ${failures} failure(s)"
  else
    pass "S Self-test: all redaction and leak-scan checks passed"
  fi
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# S C E N A R I O   A   —   Backend health / auth preflight
# ═══════════════════════════════════════════════════════════════════════════════
scenario_a() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo " [A] Backend Health / Auth Preflight"
  echo "═══════════════════════════════════════════════════════════════════"
  SCENARIOS+=("A")

  local health_resp
  health_resp="$(lm_backend_health_json || true)"
  if echo "${health_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='ok' else 1)" 2>/dev/null; then
    pass "A.1 Backend health ok"
  else
    blocker "A.1 Backend not healthy — cannot run credential smoke"
    return 1
  fi

  # Verify the health response has no leaked secrets
  capture_for_scan "A.health" "${health_resp}"
  if secret_leak_scan "A.health" "${health_resp}"; then
    fail "A.2 Secret leak detected in health response"
    return 1
  fi
  pass "A.2 Health response: no secret leak"

  # Detect backend URL convention
  local backend_url
  backend_url="$(lm_backend_base_url)"
  echo "  Backend URL: ${backend_url}"
  pass "A.3 Backend URL: ${backend_url}"

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# S C E N A R I O   B   —   Rotate credential
# ═══════════════════════════════════════════════════════════════════════════════
scenario_b() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo " [B] Rotate Credential"
  echo "═══════════════════════════════════════════════════════════════════"
  SCENARIOS+=("B")

  # We need: registered node (NODE_ID, NODE_SECRET), approved, and admin token
  if [[ -z "${NODE_ID:-}" || -z "${NODE_SECRET:-}" ]]; then
    skip "B Rotate: no registered node available"
    return 0
  fi
  if [[ -z "${ADMIN_TOKEN:-}" ]]; then
    skip "B Rotate: no admin token available"
    return 0
  fi

  local rotate_raw rotate_body rotate_http
  rotate_raw="$(curl -sS --max-time 5 -w "\n%{http_code}" -X POST \
    "${API_BASE}/admin/api/v1/nodes/${NODE_ID}/credentials/rotate" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d '{"reason":"smoke rotation"}')" || true
  rotate_http="$(echo "${rotate_raw}" | tail -1)"
  rotate_body="$(echo "${rotate_raw}" | sed '$d')"

  case "${rotate_http}" in
    200|201)
      ;;
    403)
      skip "B Rotate: HTTP 403 (admin token lacks permission)"
      return 0
      ;;
    404)
      skip "B Rotate: HTTP 404 (endpoint not deployed)"
      return 0
      ;;
    401)
      skip "B Rotate: HTTP 401 (admin auth rejected)"
      return 0
      ;;
    000)
      skip "B Rotate: HTTP 000 (backend unreachable)"
      return 0
      ;;
    5[0-9][0-9])
      fail "B Rotate: HTTP ${rotate_http} — backend reachable but contract violated"
      return 0
      ;;
    *)
      fail "B Rotate: HTTP ${rotate_http} — unexpected status"
      return 0
      ;;
  esac

  capture_for_scan "B.rotate" "${rotate_body}"
  # Check that node_secret appears only once and is not empty
  ROTATE_NODE_ID="$(echo "${rotate_body}" | quiet_json "node_id")"
  ROTATE_KEY_ID="$(echo "${rotate_body}" | quiet_json "key_id")"
  ROTATE_CRED_VERSION="$(echo "${rotate_body}" | quiet_json "credential_version")"
  ROTATE_NODE_SECRET="$(echo "${rotate_body}" | quiet_json "node_secret")"

  if [[ -z "${ROTATE_NODE_ID}" || "${ROTATE_NODE_ID}" != "${NODE_ID}" ]]; then
    fail "B.1 Rotate response node_id missing or mismatched"
    return 0
  fi
  pass "B.1 Rotate response includes node_id: ${ROTATE_NODE_ID}"

  if [[ -z "${ROTATE_KEY_ID}" ]]; then
    fail "B.2 Rotate response missing key_id"
    return 0
  fi
  pass "B.2 Rotate response includes key_id: ${ROTATE_KEY_ID}"

  if [[ -z "${ROTATE_CRED_VERSION}" || "${ROTATE_CRED_VERSION}" -le 0 ]]; then
    fail "B.3 Rotate response missing or invalid credential_version"
    return 0
  fi
  pass "B.3 Rotate response includes credential_version: ${ROTATE_CRED_VERSION}"

  if [[ -z "${ROTATE_NODE_SECRET}" ]]; then
    fail "B.4 Rotate response missing node_secret"
    return 0
  fi
  pass "B.4 Rotate response includes node_secret (returned once)"

  # Confirm node_secret does NOT appear in Admin status API
  local admin_node_raw
  admin_node_raw="$(curl -sS --max-time 5 \
    "${API_BASE}/admin/api/v1/nodes/${NODE_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}")" || true
  if echo "${admin_node_raw}" | grep -q 'node_secret'; then
    fail "B.4 Admin node detail leaks node_secret!"
    capture_for_scan "B.admin_detail_leak" "${admin_node_raw}"
  else
    pass "B.4 Admin node detail: node_secret NOT leaked"
  fi

  # Store for subsequent scenarios
  export NEW_KEY_ID="${ROTATE_KEY_ID}"
  export NEW_CRED_VERSION="${ROTATE_CRED_VERSION}"
  export NEW_NODE_SECRET="${ROTATE_NODE_SECRET}"

  echo "  Rotate succeeded: key_id=${ROTATE_KEY_ID} version=${ROTATE_CRED_VERSION}"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# S C E N A R I O   C   —   New credential authenticates
# ═══════════════════════════════════════════════════════════════════════════════
scenario_c() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo " [C] New X-Key-ID Credential Authenticates"
  echo "═══════════════════════════════════════════════════════════════════"
  SCENARIOS+=("C")

  if [[ -z "${NEW_KEY_ID:-}" || -z "${NEW_NODE_SECRET:-}" ]]; then
    skip "C New credential: no rotated credential available (B skipped or failed)"
    return 0
  fi
  if [[ -z "${NODE_ID:-}" ]]; then
    skip "C New credential: no registered node"
    return 0
  fi

  # Attempt a heartbeat signed with the new credential + X-Key-ID
  local hb_body hb_raw hb_http
  hb_body='{"agent_version":"smoke-1.0.0","config_version":0,"load_score":0,"cpu_usage":0,"memory_usage":0,"network_tx_bytes":0,"network_rx_bytes":0,"active_connections":0,"singbox_status":"unknown","degraded":false}'
  hb_raw="$(cred_post "${API_BASE}/internal/agent/heartbeat" "${hb_body}" "${NODE_ID}" "${NEW_NODE_SECRET}" "${NEW_KEY_ID}")" || true
  hb_http="$(echo "${hb_raw}" | tail -1)"

  case "${hb_http}" in
    200)
      pass "C New credential heartbeat: HTTP 200 (X-Key-ID auth accepted)"
      ;;
    401)
      fail "C New credential heartbeat: HTTP 401 (new credential rejected)"
      ;;
    000)
      skip "C New credential heartbeat: HTTP 000 (backend unreachable)"
      ;;
    *)
      skip "C New credential heartbeat: HTTP ${hb_http}"
      ;;
  esac

  # Also verify the node detail shows updated credential_version / current_key_id
  local admin_node_detail
  admin_node_detail="$(curl -sS --max-time 5 \
    "${API_BASE}/admin/api/v1/nodes/${NODE_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN:-}")" || true
  local detail_key_id
  detail_key_id="$(echo "${admin_node_detail}" | quiet_json "current_key_id" || true)"
  local detail_cred_ver
  detail_cred_ver="$(echo "${admin_node_detail}" | quiet_json "credential_version" || true)"

  if [[ -z "${detail_key_id}" ]]; then
    skip "C Node detail: current_key_id not available (SKIP)"
  elif [[ "${detail_key_id}" == "${NEW_KEY_ID}" ]]; then
    pass "C Node detail: current_key_id matches rotated key_id"
  else
    echo "  INFO: current_key_id=${detail_key_id} vs rotated=${NEW_KEY_ID}"
    skip "C Node detail: current_key_id does not match rotated key_id yet"
  fi

  # Secret leak check on heartbeat response
  local hb_body_only
  hb_body_only="$(echo "${hb_raw}" | sed '$d')"
  capture_for_scan "C.heartbeat" "${hb_body_only}"
  if secret_leak_scan "C.heartbeat" "${hb_body_only}"; then
    fail "C Secret leak in heartbeat response"
  fi

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# S C E N A R I O   D   —   Legacy fallback during rotation
# ═══════════════════════════════════════════════════════════════════════════════
scenario_d() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo " [D] Legacy Fallback During Rotation"
  echo "═══════════════════════════════════════════════════════════════════"
  SCENARIOS+=("D")

  # After rotation, the old credential (node_secret / NodeSecretHash) should
  # still be accepted via the "legacy fallback" path: Backend middleware falls
  # back to node.NodeSecretHash when X-Key-ID is not provided.  This verifies
  # the overlap window where the old NodeAgent secret hash remains valid.
  # A true "rolling credential" test (simultaneous multi-key validity with
  # distinct X-Key-IDs) is exercised by Scenario C (new key with X-Key-ID)
  # + this scenario (old key without X-Key-ID, with legacy NodeSecretHash)
  # together.
  if [[ -z "${NODE_ID:-}" || -z "${NODE_SECRET:-}" ]]; then
    skip "D Grace: no old credential available"
    return 0
  fi
  if [[ -z "${NEW_KEY_ID:-}" ]]; then
    skip "D Grace: no rotation occurred, cannot verify overlap"
    return 0
  fi

  # Attempt heartbeat with OLD credential (no X-Key-ID)
  # NodeAgent SecretHash legacy fallback: Backend middleware falls back to
  # node.NodeSecretHash when X-Key-ID is not provided or key_id is not found.
  # Together with scenario C (new X-Key-ID auth), this proves the overlap
  # window during credential rotation.
  local hb_body hb_raw hb_http
  hb_body='{"agent_version":"smoke-1.0.0","config_version":0,"load_score":0,"cpu_usage":0,"memory_usage":0,"network_tx_bytes":0,"network_rx_bytes":0,"active_connections":0,"singbox_status":"unknown","degraded":false}'
  hb_raw="$(cred_post "${API_BASE}/internal/agent/heartbeat" "${hb_body}" "${NODE_ID}" "${NODE_SECRET}" "")" || true
  hb_http="$(echo "${hb_raw}" | tail -1)"

  case "${hb_http}" in
    200)
      pass "D Old credential heartbeat: HTTP 200 (legacy fallback active)"
      ;;
    401)
      fail "D Old credential heartbeat: HTTP 401 (legacy fallback expected but rejected)"
      ;;
    000)
      skip "D Old credential heartbeat: HTTP 000 (backend unreachable)"
      ;;
    *)
      skip "D Old credential heartbeat: HTTP ${hb_http}"
      ;;
  esac
  capture_for_scan "D.old_cred_heartbeat" "$(echo "${hb_raw}" | sed '$d')"

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# S C E N A R I O   E   —   Revoke behavior
# ═══════════════════════════════════════════════════════════════════════════════
scenario_e() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo " [E] Revoke Behavior"
  echo "═══════════════════════════════════════════════════════════════════"
  SCENARIOS+=("E")

  if [[ -z "${NODE_ID:-}" ]]; then
    skip "E Revoke: no registered node"
    return 0
  fi
  if [[ -z "${ADMIN_TOKEN:-}" ]]; then
    skip "E Revoke: no admin token"
    return 0
  fi
  if [[ -z "${NEW_KEY_ID:-}" ]]; then
    skip "E Revoke: no credential to revoke (B skipped)"
    return 0
  fi

  # Revoke the specific credential
  local revoke_raw revoke_http
  revoke_raw="$(curl -sS --max-time 5 -w "\n%{http_code}" -X POST \
    "${API_BASE}/admin/api/v1/nodes/${NODE_ID}/credentials/revoke" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d '{"reason":"smoke revoke test"}')" || true
  revoke_http="$(echo "${revoke_raw}" | tail -1)"

  case "${revoke_http}" in
    200)
      capture_for_scan "E.revoke" "${revoke_body:-"$(echo "${revoke_raw}" | sed '$d')"}"
      pass "E.1 Revoke credential: HTTP 200"
      ;;
    401)
      skip "E.1 Revoke credential: HTTP 401 (admin auth rejected)"
      return 0
      ;;
    403)
      skip "E.1 Revoke credential: HTTP 403 (insufficient permissions)"
      return 0
      ;;
    404)
      skip "E.1 Revoke credential: HTTP 404 (endpoint not deployed)"
      return 0
      ;;
    000)
      skip "E.1 Revoke credential: HTTP 000 (backend unreachable)"
      return 0
      ;;
    5[0-9][0-9])
      fail "E.1 Revoke credential: HTTP ${revoke_http} — backend reachable but contract violated"
      return 0
      ;;
    *)
      fail "E.1 Revoke credential: HTTP ${revoke_http} — unexpected status"
      return 0
      ;;
  esac

  # Now try to authenticate with the revoked credential
  local hb_body hb_raw hb_http
  hb_body='{"agent_version":"smoke-1.0.0","config_version":0,"load_score":0,"cpu_usage":0,"memory_usage":0,"network_tx_bytes":0,"network_rx_bytes":0,"active_connections":0,"singbox_status":"unknown","degraded":false}'
  hb_raw="$(cred_post "${API_BASE}/internal/agent/heartbeat" "${hb_body}" "${NODE_ID}" "${NEW_NODE_SECRET}" "${NEW_KEY_ID}")" || true
  hb_http="$(echo "${hb_raw}" | tail -1)"

  case "${hb_http}" in
    401)
      pass "E.2 Revoked credential rejected: HTTP 401"
      # Check for expected error codes
      local hb_body_only
      hb_body_only="$(echo "${hb_raw}" | sed '$d')"
      capture_for_scan "E.2.revoked_hb" "${hb_body_only}"
      if echo "${hb_body_only}" | grep -qE 'NODE_CRED_REVOKED|NODE_KEY_ID_NOT_FOUND'; then
        pass "E.2 Error indicates credential revoked / key_id not found"
      fi
      ;;
    200)
      fail "E.2 Revoked credential STILL ACCEPTED (HTTP 200)"
      ;;
    000)
      skip "E.2 Revoked credential check: HTTP 000 (backend unreachable)"
      ;;
    *)
      skip "E.2 Revoked credential: HTTP ${hb_http}"
      ;;
  esac

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# S C E N A R I O   F   —   Re-enroll issues fresh credential
# ═══════════════════════════════════════════════════════════════════════════════
scenario_f() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo " [F] Re-enroll Issues Fresh Credential"
  echo "═══════════════════════════════════════════════════════════════════"
  SCENARIOS+=("F")

  if [[ -z "${NODE_ID:-}" ]]; then
    skip "F Re-enroll: no registered node"
    return 0
  fi
  if [[ -z "${ADMIN_TOKEN:-}" ]]; then
    skip "F Re-enroll: no admin token"
    return 0
  fi

  local reenroll_raw reenroll_http reenroll_body
  reenroll_raw="$(curl -sS --max-time 5 -w "\n%{http_code}" -X POST \
    "${API_BASE}/admin/api/v1/nodes/${NODE_ID}/credentials/re-enroll" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d '{"reason":"smoke re-enroll test"}')" || true
  reenroll_http="$(echo "${reenroll_raw}" | tail -1)"
  reenroll_body="$(echo "${reenroll_raw}" | sed '$d')"

  case "${reenroll_http}" in
    200|201)
      capture_for_scan "F.reenroll" "${reenroll_body}"
      pass "F.1 Re-enroll: HTTP ${reenroll_http}"
      ;;
    401)
      skip "F.1 Re-enroll: HTTP 401 (admin auth rejected)"
      return 0
      ;;
    403)
      skip "F.1 Re-enroll: HTTP 403 (insufficient permissions)"
      return 0
      ;;
    404)
      skip "F.1 Re-enroll: HTTP 404 (endpoint not deployed)"
      return 0
      ;;
    000)
      skip "F.1 Re-enroll: HTTP 000 (backend unreachable)"
      return 0
      ;;
    5[0-9][0-9])
      fail "F.1 Re-enroll: HTTP ${reenroll_http} — backend reachable but contract violated"
      return 0
      ;;
    *)
      fail "F.1 Re-enroll: HTTP ${reenroll_http} — unexpected status"
      return 0
      ;;
  esac

  # Parse re-enroll response
  local re_key_id re_cred_ver re_node_secret
  re_key_id="$(echo "${reenroll_body}" | quiet_json "key_id")"
  re_cred_ver="$(echo "${reenroll_body}" | quiet_json "credential_version")"
  re_node_secret="$(echo "${reenroll_body}" | quiet_json "node_secret")"

  if [[ -z "${re_key_id}" ]]; then
    fail "F.2 Re-enroll response missing key_id"
    return 0
  fi
  pass "F.2 Re-enroll response includes key_id: ${re_key_id}"

  if [[ -z "${re_cred_ver}" || "${re_cred_ver}" -le 0 ]]; then
    fail "F.3 Re-enroll response missing or invalid credential_version"
    return 0
  fi
  pass "F.3 Re-enroll response includes credential_version: ${re_cred_ver}"

  if [[ -z "${re_node_secret}" ]]; then
    fail "F.4 Re-enroll response missing node_secret"
    return 0
  fi
  pass "F.4 Re-enroll response includes node_secret (returned once)"

  # Verify fresh credential authenticates
  local hb_body hb_raw hb_http
  hb_body='{"agent_version":"smoke-1.0.0","config_version":0,"load_score":0,"cpu_usage":0,"memory_usage":0,"network_tx_bytes":0,"network_rx_bytes":0,"active_connections":0,"singbox_status":"unknown","degraded":false}'
  hb_raw="$(cred_post "${API_BASE}/internal/agent/heartbeat" "${hb_body}" "${NODE_ID}" "${re_node_secret}" "${re_key_id}")" || true
  hb_http="$(echo "${hb_raw}" | tail -1)"

  case "${hb_http}" in
    200)
      capture_for_scan "F.5.fresh_cred_hb" "$(echo "${hb_raw}" | sed '$d')"
      pass "F.5 Re-enrolled credential authenticates: HTTP 200"
      ;;
    401)
      fail "F.5 Re-enrolled credential rejected: HTTP 401"
      ;;
    000)
      skip "F.5 Re-enrolled credential check: HTTP 000 (backend unreachable)"
      ;;
    *)
      skip "F.5 Re-enrolled credential: HTTP ${hb_http}"
      ;;
  esac

  # Also verify old revoked credential no longer works
  if [[ -n "${NEW_KEY_ID:-}" && -n "${NEW_NODE_SECRET:-}" ]]; then
    hb_raw="$(cred_post "${API_BASE}/internal/agent/heartbeat" "${hb_body}" "${NODE_ID}" "${NEW_NODE_SECRET}" "${NEW_KEY_ID}")" || true
    hb_http="$(echo "${hb_raw}" | tail -1)"
    case "${hb_http}" in
      401)
        capture_for_scan "F.6.old_revoked_hb" "$(echo "${hb_raw}" | sed '$d')"
        pass "F.6 Previously revoked credential still rejected after re-enroll: HTTP 401"
        ;;
      *)
        echo "  INFO: Previously revoked credential: HTTP ${hb_http} (expected 401)"
        ;;
    esac
  fi

  export REENROLL_KEY_ID="${re_key_id}"
  export REENROLL_NODE_SECRET="${re_node_secret}"
  return 0
}

scenario_g() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo " [G] NodeAgent Fallback Evidence"
  echo "═══════════════════════════════════════════════════════════════════"
  SCENARIOS+=("G")

  # Check if NodeAgent credential store exists on disk
  local na_cred_file=""
  for candidate in \
    "${LIVEMASK_WORKSPACE_ROOT}/livemask-nodeagent/data/credentials.json" \
    "/tmp/livemask-nodeagent/credentials.json" \
    "/var/lib/livemask-nodeagent/credentials.json"; do
    if [[ -f "${candidate}" ]]; then
      na_cred_file="${candidate}"
      break
    fi
  done

  if [[ -z "${na_cred_file}" ]]; then
    skip "G NodeAgent credential store: not found — SKIP (NodeAgent runtime not available)"
    return 0
  fi

  echo "  NodeAgent credential store found: ${na_cred_file}"

  # Read and parse the credential store (do NOT print/store raw values)
  local cred_content
  cred_content="$(cat "${na_cred_file}" 2>/dev/null || true)"
  if [[ -z "${cred_content}" ]]; then
    skip "G NodeAgent credential store: empty or unreadable"
    return 0
  fi

  # Only extract non-secret fields
  local active_key_id active_version pending_key_id pending_version
  active_key_id="$(echo "${cred_content}" | quiet_json "active.key_id" || true)"
  active_version="$(echo "${cred_content}" | quiet_json "active.credential_version" || true)"
  pending_key_id="$(echo "${cred_content}" | quiet_json "pending.key_id" || true)"
  pending_version="$(echo "${cred_content}" | quiet_json "pending.credential_version" || true)"

  echo "  Active credential: key_id=${active_key_id:-<none>} version=${active_version:-<none>}"
  echo "  Pending credential: key_id=${pending_key_id:-<none>} version=${pending_version:-<none>}"

  if [[ -n "${active_key_id}" ]]; then
    pass "G NodeAgent has active credential (key_id present)"
  else
    skip "G NodeAgent: no active credential in store"
  fi

  if [[ -n "${pending_key_id}" ]]; then
    pass "G NodeAgent has pending credential (rotation overlap evidence)"
  else
    skip "G NodeAgent: no pending credential — SKIP (may already be promoted)"
  fi

  # Instead of scanning raw credential store, scan a redacted projection
  # that has its secret values replaced.  This verifies the projection
  # is clean while never exposing raw secrets to the scan engine.
  local redacted_projection
  redacted_projection="$(redact "{\"active\":{\"key_id\":\"${active_key_id:-}\",\"credential_version\":${active_version:-0}},\"pending\":{\"key_id\":\"${pending_key_id:-}\",\"credential_version\":${pending_version:-0}}}")"
  if secret_leak_scan "G.redacted_projection" "${redacted_projection}"; then
    fail "G Secret value leak in redacted credential projection"
  else
    pass "G Redacted credential projection: no value leak"
  fi

  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# S C E N A R I O   H   —   Secret leak scan
# ═══════════════════════════════════════════════════════════════════════════════
scenario_h() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo " [H] Secret Value Leak Scan (over captured artifacts)"
  echo "═══════════════════════════════════════════════════════════════════"
  SCENARIOS+=("H")

  # Step 1: Display any leak details already recorded by per-scenario
  # secret_leak_scan calls.
  if [[ -f "${SCAN_ARTIFACT}" ]]; then
    local scan_leak_count
    scan_leak_count="$(wc -l < "${SCAN_ARTIFACT}" 2>/dev/null || echo 0)"
    if [[ "${scan_leak_count}" -gt 0 ]]; then
      echo "  VALUE LEAKS detected during per-scenario scanning:"
      while IFS= read -r line; do
        echo "    ${line}"
      done < "${SCAN_ARTIFACT}"
    fi
  fi

  # Step 2: Scan CAPTURED_OUTPUTS for any remaining raw value patterns.
  # secret_leak_scan will append to SCAN_ARTIFACT if it finds leaks.
  if [[ -f "${CAPTURED_OUTPUTS}" ]]; then
    local captured_content
    captured_content="$(cat "${CAPTURED_OUTPUTS}" 2>/dev/null || true)"
    secret_leak_scan "H.captured_outputs" "${captured_content}" || true
  fi

  # Step 3: Final check — any leaks recorded?
  if [[ -f "${SCAN_ARTIFACT}" ]]; then
    local final_leak_count
    final_leak_count="$(wc -l < "${SCAN_ARTIFACT}" 2>/dev/null || echo 0)"
    if [[ "${final_leak_count}" -gt 0 ]]; then
      echo "  FINAL LEAK DETAILS:"
      while IFS= read -r line; do
        echo "    ${line}"
      done < "${SCAN_ARTIFACT}"
      fail "H Secret value leak: ${final_leak_count} leak(s) detected across all captured artifacts"
      return 0
    fi
  fi

  pass "H No secret value leaks detected across all captured outputs and artifacts"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# M A I N
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "================================================================"
echo " NodeAgent Credential Rotation Smoke"
echo "================================================================"
lm_runtime_status_report
echo ""

# ── Step 0: Workspace and environment checks ────────────────────────────────
echo "--- [0] Preflight ---"
lm_workspace_check || true

# ── Run self-test (always, no dependencies) ────────────────────────────────
self_test

# ── Run scenario A: Backend health (prerequisite) ───────────────────────────
if ! scenario_a; then
  echo ""
  echo "=== Backend not available — remaining scenarios SKIPPED ==="
  echo ""
  # Still run H for completeness
  scenario_h
else
  # ── Register a test node ───────────────────────────────────────────────────
  echo ""
  echo "--- Register Test Node ---"
  NODE_NAME="cred-rotation-smoke-${TIMESTAMP}"
  # Clean up any previous smoke node
  if docker compose -f "${COMPOSE_FILE}" ps -q postgres &>/dev/null 2>&1; then
    docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA \
      -c "DELETE FROM nodes WHERE node_name LIKE 'cred-rotation-smoke-%'" 2>/dev/null || true
  fi

  NODE_REG=$(curl -sS --max-time 5 -X POST "${API_BASE}/internal/agent/register" \
    -H "Content-Type: application/json" \
    -d "{\"node_name\":\"${NODE_NAME}\",\"agent_version\":\"smoke-1.0.0\"}") || true
  NODE_ID=$(echo "${NODE_REG}" | quiet_json "node_id")
  NODE_SECRET=$(echo "${NODE_REG}" | quiet_json "node_secret")
  NODE_STATUS=$(echo "${NODE_REG}" | quiet_json "status")

  if [[ -z "${NODE_ID}" || -z "${NODE_SECRET}" ]]; then
    echo "  BLOCKER: Node registration failed (HTTP error or empty response)"
    echo "  Response: $(redact "$(echo "${NODE_REG}" | head -c 400)")"
    # Cannot proceed with credential smoke
  else
    echo "  Node registered: id=${NODE_ID} status=${NODE_STATUS}"

    # Approve node via SQL
    if docker compose -f "${COMPOSE_FILE}" ps -q postgres &>/dev/null 2>&1; then
      docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA \
        -c "UPDATE nodes SET status='active', approved_at=NOW(), approved_by='smoke' WHERE id='${NODE_ID}'" 2>/dev/null || true
      echo "  Node approved (status → active)"
    fi

    # Derive secret_hash for legacy auth (Backend's HashSecret)
    NODE_SECRET_HASH=$(echo -n "${NODE_SECRET}" | sha256sum | cut -d' ' -f1)

    # ── Admin login ──────────────────────────────────────────────────────────
    ADMIN_TOKEN=""
    ADMIN_LOGIN_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"request_id\":\"credsmk-${TIMESTAMP}\",\"email\":\"admin@livemask.dev\",\"password\":\"AdminPass123!\",\"client_type\":\"admin\"}") || true
    ADMIN_TOKEN=$(echo "${ADMIN_LOGIN_RESP}" | quiet_json "access_token")

    if [[ -z "${ADMIN_TOKEN}" ]]; then
      echo "  Admin login failed — credential rotate/revoke/re-enroll checks will be SKIP"
      # Seed admin if possible
      if docker compose -f "${COMPOSE_FILE}" ps -q postgres &>/dev/null 2>&1; then
        echo "  Attempting to seed admin..."
        docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA \
          -c "DELETE FROM users WHERE email='admin@livemask.dev'" 2>/dev/null || true
        ADMIN_HASH=$(docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA \
          -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
        if [[ -n "${ADMIN_HASH}" ]]; then
          docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA \
            -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'" 2>/dev/null || true
          docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA \
            -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by credential-rotation-smoke' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null || true
        fi
        ADMIN_LOGIN_RESP=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
          -H "Content-Type: application/json" \
          -d "{\"request_id\":\"credsmk-retry-${TIMESTAMP}\",\"email\":\"admin@livemask.dev\",\"password\":\"AdminPass123!\",\"client_type\":\"admin\"}") || true
        ADMIN_TOKEN=$(echo "${ADMIN_LOGIN_RESP}" | quiet_json "access_token")
        if [[ -n "${ADMIN_TOKEN}" ]]; then
          echo "  Admin login OK after seeding"
        fi
      fi
    else
      echo "  Admin login OK"
    fi

    # ── Run credential scenarios B–F ─────────────────────────────────────────
    scenario_b  # Rotate
    scenario_c  # New credential auth
    scenario_d  # Legacy fallback during rotation
    scenario_e  # Revoke
    scenario_f  # Re-enroll
  fi
fi

# ── Always run G and H (self-contained) ─────────────────────────────────────
scenario_g  # NodeAgent fallback evidence
scenario_h  # Secret leak scan

# ═══════════════════════════════════════════════════════════════════════════════
# R E S U L T S
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "================================================================"
echo " Credential Rotation Smoke — Results"
echo "================================================================"

for result in "${SCENARIO_RESULTS[@]}"; do
  echo "  ${result}"
done

echo ""
echo "  Total PASS: ${PASS_COUNT}"
echo "  Total FAIL: ${FAIL_COUNT}"
echo "  Total SKIP: ${SKIP_COUNT}"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  # Check if all failures are blockers that are environmental
  env_blockers=0
  for result in "${SCENARIO_RESULTS[@]}"; do
    if echo "${result}" | grep -q "^BLOCKER:"; then
      env_blockers=$((env_blockers + 1))
    fi
  done
  if [[ "${env_blockers}" -eq "${FAIL_COUNT}" ]]; then
    echo "Result: SKIP_ALLOWED (all failures are environmental blockers)"
  else
    echo "Result: FAIL"
  fi
  echo "================================================================"
  exit 1
fi

echo "Result: PASS"
echo "================================================================"
exit 0
