#!/usr/bin/env bash
set -euo pipefail
CI_CD="/Users/sammytan/Developer/LiveMask/livemask-ci-cd"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  [PASS] $*"; }
fail() { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
echo "=== Claude Loop Idle Monitor Smoke ==="
echo "--- 1. Executables ---"
[[ -x "${CI_CD}/scripts/claude-loop-preflight.sh" ]] && pass "preflight" || fail "preflight"
[[ -x "${CI_CD}/scripts/claude-loop-idle-monitor.sh" ]] && pass "idle-monitor" || fail "idle-monitor"
echo "--- 2. Return codes ---"
set +e; OUT=$("${CI_CD}/scripts/claude-loop-preflight.sh" 2>&1); RC=$?; set -e
[[ "${RC}" -eq 0 ]] && pass "IDLE (exit 0)" || true
[[ "${RC}" -eq 1 ]] && pass "WORK_AVAILABLE (exit 1, expected when work exists)" || true
[[ "${RC}" -eq 2 ]] && pass "BLOCKED (exit 2, expected when issues open/dirty)" || true
echo "--- 3. Channel output ---"
echo "${OUT}" | grep -q "Channel 1: SAP" && pass "SAP" || fail "SAP"
echo "${OUT}" | grep -q "Channel 2: Planner" && pass "Planner" || fail "Planner"
echo "${OUT}" | grep -q "Channel 3: Git" && pass "Git" || fail "Git"
echo "${OUT}" | grep -q "Channel 4: GitHub" && pass "GitHub" || fail "GitHub"
echo "--- 4. Syntax ---"
bash -n "${CI_CD}/scripts/claude-loop-preflight.sh" && pass "preflight" || fail "preflight"
bash -n "${CI_CD}/scripts/claude-loop-idle-monitor.sh" && pass "monitor" || fail "monitor"
echo "--- 5. Git diff ---"
cd "${CI_CD}" && git diff --check && pass "clean" || fail "dirty"
echo "============================================"
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "============================================"
[[ ${FAIL} -gt 0 ]] && exit 1
exit 0
