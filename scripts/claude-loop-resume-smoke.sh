#!/usr/bin/env bash
# TASK-CICD-CLAUDE-LOOP-RESUME-AFTER-BLOCKED-EVIDENCE-001
# Smoke test: loop preflight with active-blockers, simulated SAP lifecycle,
# and loop continuity after blocker resolution.
set -euo pipefail

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  [PASS] $*"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }

DOCS_DIR="/Users/sammytan/Developer/LiveMask/livemask-docs"
CLI="${DOCS_DIR}/scripts/supervisor-action.py"
ACTIONS_DIR="${DOCS_DIR}/docs/development/supervisor-actions"

echo "=== Claude Loop Resume Smoke ==="
echo ""

# Cleanup any leftover test SAPs
rm -f "${ACTIONS_DIR}"/SAP-TEST-LOOP-*.json "${ACTIONS_DIR}"/archive/SAP-TEST-LOOP-*.json

# 1. Preflight: --status open --blocks-loop true (legacy)
echo "--- 1. Legacy preflight ---"
"${CLI}" list --status open --blocks-loop true 2>&1 | grep -q "No matching" && pass "legacy preflight clean" || fail "legacy preflight"

# 2. Preflight: --active-blockers --blocks-loop true
echo "--- 2. Active-blockers preflight ---"
"${CLI}" list --active-blockers --blocks-loop true 2>&1 | grep -q "No matching" && pass "active-blockers preflight clean" || fail "active-blockers"

# 3. Create a test SAP
echo "--- 3. Simulated blocker ---"
AID=$(echo "$("${CLI}" create --task-id TASK-TEST-LOOP-001 --action REQUEST_CHANGES --severity warning --repo livemask-admin --reason "test loop continuity" --required-change "collect evidence" --target-agent Claude --blocks-loop true 2>&1)" | grep -oE 'SAP-REQUEST-CHANGES-[0-9]{8}-[0-9]{6}' | head -1 | tr -d '[:space:]')
[[ -n "${AID}" ]] && pass "created test SAP: ${AID}" || { fail "create failed"; exit 1; }

# 4. Preflight detects open blocker
echo "--- 4. Detects open blocker ---"
"${CLI}" list --status open --blocks-loop true 2>&1 | grep -q "${AID}" && pass "legacy preflight detects open SAP" || fail "legacy preflight missed SAP"
"${CLI}" list --active-blockers --blocks-loop true 2>&1 | grep -q "${AID}" && pass "active-blockers detects open SAP" || fail "active-blockers missed SAP"

# 5. Ack the SAP
echo "--- 5. Ack transitions ---"
"${CLI}" ack "${AID}" --by Claude --notes "testing loop continuity" >/dev/null 2>&1 && pass "ack succeeds" || fail "ack failed"

# 6. Active-blockers still detects ack SAP (key behavior)
echo "--- 6. Detects ack blocker ---"
"${CLI}" list --active-blockers --blocks-loop true 2>&1 | grep -q "${AID}" && pass "active-blockers detects ack SAP" || fail "active-blockers missed ack SAP"

# 7. Resolve the SAP
echo "--- 7. Resolve ---"
"${CLI}" resolve "${AID}" --by Claude --how "evidence collected" --new-commit abc1234 >/dev/null 2>&1 && pass "resolve succeeds" || fail "resolve failed"

# 8. Active-blockers no longer detects resolved SAP
echo "--- 8. Post-resolution preflight ---"
"${CLI}" list --active-blockers --blocks-loop true 2>&1 | grep -q "No matching" && pass "active-blockers clean after resolve" || fail "active-blockers still blocked"

# 9. Archive
echo "--- 9. Archive ---"
"${CLI}" archive "${AID}" >/dev/null 2>&1 && pass "archive succeeds" || fail "archive failed"

# 10. Final preflight clean
echo "--- 10. Final preflight ---"
"${CLI}" list --active-blockers --blocks-loop true 2>&1 | grep -q "No matching" && pass "final preflight clean" || fail "final preflight blocked"

echo ""
echo "============================================"
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "============================================"
[[ ${FAIL} -gt 0 ]] && exit 1
exit 0
