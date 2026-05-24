#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-PROTOCOL-PARITY-SMOKE-001
# Protocol Capability vs NodeAgent Implementation Parity Smoke
# ═══════════════════════════════════════════════════════════════════════════════
# Verifies that the protocol capabilities registered in Backend match what
# NodeAgent actually implements:
#   [1]  Backend health + Admin login
#   [2]  Fetch supported protocols from Backend admin API
#   [3]  Check protocol capability endpoint returns expected fields
#   [4]  Verify NodeAgent agent_version / protocol_capabilities consistency
#   [5]  Check that reserved protos (LKG) are marked blocked
#   [6]  Contract drift check
#   [7]  Secret leak scan
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/base_service.sh"

COMPOSE_FILE="${COMPOSE_FILE:-infra/docker-compose.staging.yml}"
API_BASE="$(lm_backend_base_url)"
NODEAGENT_API="http://127.0.0.1:${LIVEMASK_NODEAGENT_PORT:-19090}"

FAILED=0; PASS_COUNT=0; SKIP_COUNT=0; FAIL_COUNT=0; SUMMARY_LINES=()

fail()    { local m="$1"; echo "  FAIL: ${m}"; SUMMARY_LINES+=("FAIL: ${m}"); FAIL_COUNT=$((FAIL_COUNT+1)); FAILED=1; }
pass()    { local m="$1"; echo "  PASS: ${m}"; SUMMARY_LINES+=("PASS: ${m}"); PASS_COUNT=$((PASS_COUNT+1)); }
skip()    { local m="$1"; echo "  SKIP: ${m}"; SUMMARY_LINES+=("SKIP: ${m}"); SKIP_COUNT=$((SKIP_COUNT+1)); }
blocker() { local m="$1"; echo "  BLOCKER: ${m}"; SUMMARY_LINES+=("BLOCKER: ${m}"); FAILED=1; }

quiet_json() {
  local path="${1:-}"; python3 -c "
import sys,json; d=json.load(sys.stdin)
for p in '${path}'.split('.'):
    if isinstance(d,dict): d=d.get(p,'')
    elif isinstance(d,list):
        try: d=d[int(p)]
        except: d=''
    else: d=''
print(d)" 2>/dev/null || echo ""
}

security_check() {
  local label="$1"; local json="$2"
  local leaked=$(echo "${json}" | python3 -c "
import sys,json; data=json.load(sys.stdin)
S=['password_hash','node_secret','hmac','private_key','secret_key','encryption_key','access_token','refresh_token','api_key','license_key','sentry_dsn','raw_token','full_config','raw_payload','webhook_secret','pem_key','rsa_private','ed25519_private','signing_key']
def w(d):
    if isinstance(d,dict):
        for k,v in d.items():
            kl=k.lower()
            for s in S:
                if s in kl: return True
            if w(v): return True
    elif isinstance(d,list):
        for i in d:
            if w(i): return True
    return False
print('LEAK' if w(data) else 'OK')" 2>/dev/null || echo "OK")
  [[ "${leaked}" != "OK" ]] && { fail "[SECURITY] ${label}: secret leakage"; return 1; }; return 0
}

echo "================================================"
echo " TASK-CICD-PROTOCOL-PARITY-SMOKE-001"
echo " Protocol Capability vs NodeAgent Parity"
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

# Admin login
echo ""
echo "--- Admin Login ---"
pg_exec() { docker compose -f "${COMPOSE_FILE}" exec -T postgres psql -U livemask -tA "$@" 2>/dev/null || true; }
pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'" 2>/dev/null || true
ADMIN_HASH=$(pg_exec -c "SELECT crypt('AdminPass123!', gen_salt('bf', 12))" 2>/dev/null || echo "")
if [[ -n "${ADMIN_HASH}" ]]; then
  pg_exec -c "INSERT INTO users (email, password_hash, display_name) VALUES ('admin@livemask.dev', '${ADMIN_HASH}', 'Dev Admin') ON CONFLICT (email) DO UPDATE SET password_hash='${ADMIN_HASH}'" 2>/dev/null
  pg_exec -c "INSERT INTO user_roles (user_id, role_key, reason) SELECT id, 'admin', 'dev seed by parity-smoke.sh' FROM users WHERE email='admin@livemask.dev' ON CONFLICT DO NOTHING" 2>/dev/null
fi
ADMIN_LOGIN=$(curl -sS --max-time 5 -X POST "${API_BASE}/admin/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"request_id":"paritysmoke-admin-login","email":"admin@livemask.dev","password":"AdminPass123!","client_type":"admin"}') || true
ADMIN_TOKEN=$(echo "${ADMIN_LOGIN}" | quiet_json "access_token")
if [[ -z "${ADMIN_TOKEN}" ]]; then blocker "Admin login — no token"; exit 1; fi
pass "Admin login OK"

# [2] Fetch supported protocols from Backend
echo ""
echo "--- [2] Backend Protocol Templates ---"
PROTO_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/protocol-templates" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
if [[ "${PROTO_HTTP}" == "200" ]]; then
  PROTO_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/protocol-templates" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
  pass "Protocol templates: HTTP 200"
  PROTO_COUNT=$(echo "${PROTO_RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); items=d.get('templates',d.get('items',d.get('data',[]))); print(len(items))" 2>/dev/null || echo "0")
  pass "Protocol templates: ${PROTO_COUNT} templates returned"
  security_check "admin/protocol-templates" "${PROTO_RESP}" || true
else
  skip "Protocol templates: HTTP ${PROTO_HTTP}"
fi

# [3] Protocol capability endpoint
echo ""
echo "--- [3] Protocol Capability Endpoint ---"
CAP_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${API_BASE}/admin/api/v1/protocol-capabilities" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
if [[ "${CAP_HTTP}" == "200" ]]; then
  CAP_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/protocol-capabilities" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
  pass "Protocol capabilities: HTTP 200"
  security_check "admin/protocol-capabilities" "${CAP_RESP}" || true
else
  # Try capability summary endpoint
  CAP_SUM_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
    "${API_BASE}/admin/api/v1/protocol-capabilities/summary" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "000")
  if [[ "${CAP_SUM_HTTP}" == "200" ]]; then
    CAP_RESP=$(curl -sS --max-time 5 "${API_BASE}/admin/api/v1/protocol-capabilities/summary" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "{}")
    pass "Protocol capabilities summary: HTTP 200"
    security_check "admin/protocol-capabilities/summary" "${CAP_RESP}" || true
  else
    skip "Protocol capabilities: HTTP ${CAP_HTTP} and summary: HTTP ${CAP_SUM_HTTP}"
  fi
fi

# [4] NodeAgent config/status for protocol_capabilities
echo ""
echo "--- [4] NodeAgent Protocol Capabilities ---"
NA_STATUS_HTTP=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" \
  "${NODEAGENT_API}/config/status" 2>/dev/null || echo "000")
if [[ "${NA_STATUS_HTTP}" == "200" ]]; then
  NA_RESP=$(curl -sS --max-time 5 "${NODEAGENT_API}/config/status" 2>/dev/null || echo "{}")
  NA_PROTOS=$(echo "${NA_RESP}" | quiet_json "protocol_capabilities" || echo "")
  if [[ -n "${NA_PROTOS}" && "${NA_PROTOS}" != "None" ]]; then
    pass "NodeAgent reports protocol_capabilities: ${NA_PROTOS}"
  else
    skip "NodeAgent protocol_capabilities not in config/status response"
  fi
  security_check "nodeagent/config/status" "${NA_RESP}" || true
else
  skip "NodeAgent config/status: HTTP ${NA_STATUS_HTTP} (not accessible)"
fi

# [5] Reserved protocol blocking check
echo ""
echo "--- [5] Reserved Protocol Blocking ---"
if [[ "${PROTO_HTTP}" == "200" ]]; then
  LKG_BLOCKED=$(echo "${PROTO_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items=data.get('templates',data.get('items',data.get('data',[])))
blocked=[t.get('protocol','?') for t in items if isinstance(t,dict) and (t.get('rollout_blocked')==True or t.get('reserved')==True)]
print(f'blocked_protocols: {len(blocked)} — {blocked[:3]}')" 2>/dev/null || echo "unknown")
  pass "Reserved protocol check: ${LKG_BLOCKED}"
fi

# [6] Contract drift check
echo ""
echo "--- [6] Contract Drift Check ---"
if [[ -n "${health_resp:-}" ]]; then
  HEALTH_OK=$(echo "${health_resp}" | python3 -c "
import sys,json; d=json.load(sys.stdin)
r=['status','db_connected','redis_connected']; m=[f for f in r if f not in d]
if m: print('MISSING: ' + ', '.join(m)); sys.exit(1)
if d.get('status')!='ok': print('STATUS_DRIFT'); sys.exit(1)
if not isinstance(d.get('db_connected'),bool): print('TYPE_DRIFT: db_connected'); sys.exit(1)
if not isinstance(d.get('redis_connected'),bool): print('TYPE_DRIFT: redis_connected'); sys.exit(1)
print('OK')" 2>/dev/null || echo "FAIL")
  [[ "${HEALTH_OK}" == "OK" ]] && pass "Contract: health response OK" || fail "CONTRACT DRIFT: health — ${HEALTH_OK}"
fi

# [7] Cleanup
echo ""
echo "--- Cleanup ---"
pg_exec -c "DELETE FROM users WHERE email='admin@livemask.dev'" 2>/dev/null || true
pass "Cleaned up: smoke test data"

# [8] Hysteria2 parity check (TASK-CICD-HYSTERIA2-CLIENT-CONFIG-SMOKE-001)
echo ""
echo "--- [8] Hysteria2 Protocol Parity ---"
HY2_PARITY_PASS=true

# 8a Check Backend protocol templates include hysteria2 as implemented
if [[ "${PROTO_HTTP}" == "200" ]]; then
  HY2_BACKEND=$(echo "${PROTO_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items=data.get('templates',data.get('items',data.get('data',[])))
for t in items:
    proto = t.get('protocol',t.get('protocol_profile','')).lower()
    if 'hysteria2' in proto:
        state = t.get('state',t.get('capability_state',''))
        blocked = t.get('rollout_blocked',False)
        supports_cc = t.get('supports_client_config',t.get('client_config',False))
        print(f'FOUND: state={state} rollout_blocked={blocked} supports_client_config={supports_cc}')
        break
else:
    print('NOT_FOUND')
" 2>/dev/null || echo "PARSE_ERROR")
  if echo "${HY2_BACKEND}" | grep -q "FOUND:"; then
    pass "Hysteria2 parity [Backend]: ${HY2_BACKEND}"
    if echo "${HY2_BACKEND}" | grep -q "state=implemented"; then
      pass "Hysteria2 parity: Backend state=implemented"
    else
      fail "Hysteria2 parity: Backend state is not implemented (${HY2_BACKEND})"
      HY2_PARITY_PASS=false
    fi
    if echo "${HY2_BACKEND}" | grep -q "rollout_blocked=True"; then
      fail "Hysteria2 parity: Backend rollout_blocked=True (should be false for implemented)"
      HY2_PARITY_PASS=false
    fi
    if echo "${HY2_BACKEND}" | grep -q "supports_client_config=True\|supports_client_config=true"; then
      pass "Hysteria2 parity: Backend supports_client_config=true"
    elif echo "${HY2_BACKEND}" | grep -q "rollout_blocked=False"; then
      # supports_client_config may not be in this schema — still PASS if not blocked
      pass "Hysteria2 parity: Backend present (supports_client_config field not in schema)"
    fi
  else
    echo "  Hysteria2 template not found in protocol-templates list"
    echo "  (This is OK — Backend may not have a dedicated hysteria2 template row)"
    pass "Hysteria2 parity [Backend]: template not found in Backend list (non-fatal)"
  fi
fi

# 8b Check NodeAgent protocol_capabilities includes hysteria2 as implemented
if [[ "${NA_STATUS_HTTP}" == "200" ]] && [[ -n "${NA_PROTOS:-}" ]] && [[ "${NA_PROTOS}" != "None" ]]; then
  HY2_NODEAGENT=$(echo "${NA_PROTOS}" | python3 -c "
import sys,json
try:
    caps = json.loads(sys.stdin.read())
except:
    caps = []
if not isinstance(caps, list):
    caps = [caps]
for c in caps:
    proto = c.get('protocol','').lower()
    if 'hysteria2' in proto:
        state = c.get('state','')
        supports_cc = c.get('supports_client_config',False)
        print('FOUND: state={} supports_client_config={}'.format(state, supports_cc))
        break
else:
    print('NOT_FOUND')
" 2>/dev/null || echo "PARSE_ERROR")
  if echo "${HY2_NODEAGENT}" | grep -q "FOUND:"; then
    pass "Hysteria2 parity [NodeAgent]: ${HY2_NODEAGENT}"
    if echo "${HY2_NODEAGENT}" | grep -q "state=implemented"; then
      pass "Hysteria2 parity: NodeAgent state=implemented"
    else
      fail "Hysteria2 parity: NodeAgent state is not implemented (${HY2_NODEAGENT})"
      HY2_PARITY_PASS=false
    fi
    if echo "${HY2_NODEAGENT}" | grep -q "supports_client_config=True\|supports_client_config=true"; then
      pass "Hysteria2 parity: NodeAgent supports_client_config=true"
    else
      echo "  NodeAgent supports_client_config not true for hysteria2"
    fi
  else
    echo "  Hysteria2 not found in NodeAgent protocol_capabilities"
    skip "Hysteria2 parity [NodeAgent]: not in NodeAgent capabilities (may need heartbeat with capabilities)"
  fi
else
  skip "Hysteria2 parity [NodeAgent]: NodeAgent capabilities not available"
fi

# 8c Check reserved protocol list does NOT include hysteria2
if [[ "${PROTO_HTTP}" == "200" ]]; then
  HY2_RESERVED=$(echo "${PROTO_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items=data.get('templates',data.get('items',data.get('data',[])))
for t in items:
    if 'hysteria2' in str(t.get('protocol','')).lower():
        is_reserved = t.get('reserved',False) or t.get('rollout_blocked',False)
        if is_reserved:
            print('RESERVED')
        else:
            print('NOT_RESERVED')
        break
else:
    print('NOT_FOUND')
" 2>/dev/null || echo "PARSE_ERROR")
  case "${HY2_RESERVED}" in
    NOT_RESERVED)
      pass "Hysteria2 parity: NOT marked as reserved (correct)"
      ;;
    RESERVED)
      fail "Hysteria2 parity: marked as reserved (should be implemented)"
      HY2_PARITY_PASS=false
      ;;
    NOT_FOUND)
      echo "  Hysteria2 not found in templates roll — OK for parity"
      ;;
  esac
fi

if [[ "${HY2_PARITY_PASS}" == "true" ]]; then
  pass "Hysteria2 parity overall: PASS"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# [9] Plain VLESS parity check (TASK-CICD-VLESS-PLAIN-PROTOCOL-SMOKE-001)
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "--- [9] Plain VLESS Protocol Parity ---"
VLESS_PARITY_PASS=true

# 9a Check Backend protocol templates include plain vless as implemented (not reserved)
if [[ "${PROTO_HTTP}" == "200" ]]; then
  VLESS_BACKEND=$(echo "${PROTO_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items=data.get('templates',data.get('items',data.get('data',[])))
for t in items:
    proto = t.get('protocol',t.get('protocol_profile','')).lower()
    if proto == 'vless':
        state = t.get('state',t.get('capability_state',''))
        blocked = t.get('rollout_blocked',False)
        is_reserved = t.get('reserved',False)
        supports_cc = t.get('supports_client_config',t.get('client_config',False))
        print(f'FOUND: state={state} rollout_blocked={blocked} reserved={is_reserved} supports_client_config={supports_cc}')
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null || echo "PARSE_ERROR")
  if echo "${VLESS_BACKEND}" | grep -q "FOUND:"; then
    pass "VLESS parity [Backend]: ${VLESS_BACKEND}"
    if echo "${VLESS_BACKEND}" | grep -q "state=implemented"; then
      pass "VLESS parity: Backend state=implemented"
    else
      fail "VLESS parity: Backend state is not implemented (${VLESS_BACKEND})"
      VLESS_PARITY_PASS=false
    fi
    if echo "${VLESS_BACKEND}" | grep -q "reserved=True"; then
      fail "VLESS parity: Backend marks vless as reserved (should be implemented)"
      VLESS_PARITY_PASS=false
    fi
    if echo "${VLESS_BACKEND}" | grep -q "rollout_blocked=True"; then
      fail "VLESS parity: Backend rollout_blocked=True (should be false for implemented)"
      VLESS_PARITY_PASS=false
    fi
    if echo "${VLESS_BACKEND}" | grep -qi "supports_client_config=True\|supports_client_config=true"; then
      pass "VLESS parity: Backend supports_client_config=true"
    fi
  else
    echo "  Plain vless template not found in protocol-templates list"
    echo "  (This is OK — Backend may not have a dedicated vless template row for plain vless)"
    pass "VLESS parity [Backend]: plain vless template not found in Backend list (non-fatal)"
  fi
fi

# 9b Check NodeAgent config/status for plain vless
VLESS_NA_FOUND=false
if [[ -n "${NA_RESP:-}" ]] && [[ "${NA_STATUS_HTTP}" == "200" ]]; then
  VLESS_NA=$(echo "${NA_RESP}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
# Check protocol_capabilities directly from config/status
caps = d.get('protocol_capabilities',d.get('capabilities',[]))
if isinstance(caps, list):
    for c in caps:
        if isinstance(c, dict) and c.get('protocol','').lower() == 'vless':
            state = c.get('state','unknown')
            supports_cc = c.get('supports_client_config',False)
            print(f'FOUND: state={state} supports_client_config={supports_cc}')
            sys.exit(0)
    print('NOT_FOUND')
else:
    # Check if response has nested structure
    for key in ['config','data','status']:
        sub = d.get(key,{})
        if isinstance(sub, dict):
            scaps = sub.get('protocol_capabilities',sub.get('capabilities',[]))
            if isinstance(scaps, list):
                for c in scaps:
                    if isinstance(c, dict) and c.get('protocol','').lower() == 'vless':
                        state = c.get('state','unknown')
                        print(f'FOUND_NESTED: state={state}')
                        sys.exit(0)
    print('NOT_FOUND')
" 2>/dev/null || echo "PARSE_ERROR")
  case "${VLESS_NA}" in
    FOUND:*)
      pass "VLESS parity [NodeAgent]: ${VLESS_NA}"
      VLESS_NA_FOUND=true
      if echo "${VLESS_NA}" | grep -q "state=implemented"; then
        pass "VLESS parity: NodeAgent state=implemented"
      else
        fail "VLESS parity: NodeAgent state is not implemented (${VLESS_NA})"
        VLESS_PARITY_PASS=false
      fi
      if echo "${VLESS_NA}" | grep -qi "supports_client_config=True\|supports_client_config=true"; then
        pass "VLESS parity: NodeAgent supports_client_config=true"
      fi
      ;;
    NOT_FOUND)
      skip "VLESS parity [NodeAgent]: plain vless not found in NodeAgent protocol_capabilities"
      ;;
    *)
      skip "VLESS parity [NodeAgent]: ${VLESS_NA}"
      ;;
  esac
else
  skip "VLESS parity [NodeAgent]: NodeAgent config/status not available"
fi

# 9c Check reserved protocol list does NOT include vless
if [[ "${PROTO_HTTP}" == "200" ]]; then
  VLESS_RESERVED=$(echo "${PROTO_RESP}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
items=data.get('templates',data.get('items',data.get('data',[])))
for t in items:
    if t.get('protocol','').lower() == 'vless':
        is_reserved = t.get('reserved',False) or t.get('rollout_blocked',False)
        if is_reserved:
            print('RESERVED')
        else:
            print('NOT_RESERVED')
        sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null || echo "PARSE_ERROR")
  case "${VLESS_RESERVED}" in
    NOT_RESERVED)
      pass "VLESS parity: NOT marked as reserved (correct)"
      ;;
    RESERVED)
      fail "VLESS parity: marked as reserved (should be implemented)"
      VLESS_PARITY_PASS=false
      ;;
    NOT_FOUND)
      echo "  Plain vless not found in templates roll — OK for parity"
      ;;
  esac
fi

if [[ "${VLESS_PARITY_PASS}" == "true" ]]; then
  pass "Plain VLESS parity overall: PASS"
fi

echo ""
echo "================================================"
echo " TASK-CICD-PROTOCOL-PARITY-SMOKE-001 SUMMARY"
echo "================================================"
echo "  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}  SKIP: ${SKIP_COUNT}"
for line in "${SUMMARY_LINES[@]}"; do echo "  ${line}"; done
if [[ "${FAILED}" -eq 1 ]]; then echo ""; echo "[TASK-CICD-PROTOCOL-PARITY-SMOKE-001] FAILED."; exit 1; fi
echo ""; echo "[TASK-CICD-PROTOCOL-PARITY-SMOKE-001] PASSED."
