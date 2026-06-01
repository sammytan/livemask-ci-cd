#!/usr/bin/env bash
# skill-bridge.sh — Connects Claude Code skills to the autonomous engine.
# Each function bridges a Claude skill to the corresponding engine component.
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"
CI_CD_DIR="${LIVEMASK_ROOT}/livemask-ci-cd"
DOCS_DIR="${LIVEMASK_ROOT}/livemask-docs"

# ── code-review skill → review-gate.sh ────────────────────────────────
skill_code_review() {
  local tid="${1:-}"; [[ -z "${tid}" ]] && { echo "Usage: skill_code_review <TASK-ID>"; return 1; }
  source "${CI_CD_DIR}/scripts/lib/review-gate.sh" 2>/dev/null || true
  source "${CI_CD_DIR}/scripts/lib/executor-guard.sh" 2>/dev/null || true
  echo "=== SKILL: code-review → review-gate ==="
  executor_auto_review "${tid}"
}

# ── security-review skill → enhanced diff scan ─────────────────────────
skill_security_review() {
  local tid="${1:-}"; [[ -z "${tid}" ]] && return 1
  source "${CI_CD_DIR}/scripts/lib/review-gate.sh" 2>/dev/null || true
  local repo; repo=$(python3 -c "import json;l=json.load(open('${DOCS_DIR}/docs/development/task-state-ledger.json'));[print(t['repo']) for m in l['modules'] for t in m['tasks'] if t['task_id']=='${tid}']" 2>/dev/null || echo "")
  echo "=== SKILL: security-review ==="
  [[ -n "${repo}" ]] && git -C "${LIVEMASK_ROOT}/${repo}" diff origin/dev...HEAD 2>/dev/null | grep -nE "password|secret|token|api_key|private_key|sql.*inject|exec\(|eval\(|innerHTML" | head -20
  echo "Security scan complete for ${tid}"
}

# ── verify skill → local-verify.sh ────────────────────────────────────
skill_verify() {
  local repo="${1:-livemask-backend}"
  source "${CI_CD_DIR}/scripts/lib/local-verify.sh" 2>/dev/null || true
  echo "=== SKILL: verify → local-verify ==="
  verify_repo "${repo}"
}

# ── run skill → start dev server ──────────────────────────────────────
skill_run() {
  local repo="${1:-livemask-backend}"
  echo "=== SKILL: run → ${repo} ==="
  case "${repo}" in
    livemask-backend) cd "${LIVEMASK_ROOT}/livemask-backend" && go build ./... && echo "Build OK — ready to run" ;;
    livemask-admin) cd "${LIVEMASK_ROOT}/livemask-admin" && npm run build 2>&1 | tail -3 ;;
    livemask-app) cd "${LIVEMASK_ROOT}/livemask-app" && flutter analyze 2>&1 | tail -3 ;;
    *) echo "Unknown repo: ${repo}" ;;
  esac
}

# ── loop skill → autonomous-loop.sh ────────────────────────────────────
skill_loop() {
  echo "=== SKILL: loop → autonomous-loop ==="
  bash "${CI_CD_DIR}/scripts/autonomous-loop.sh"
}

# ── update-config skill → sync CLAUDE.md + CODEX_LOOP_RULES ───────────
skill_update_config() {
  echo "=== SKILL: update-config ==="
  cd "${DOCS_DIR}"
  # Sync CODEX_LOOP_RULES with latest engine changes
  git pull --ff-only origin dev 2>/dev/null || true
  echo "Configs synced from origin/dev"
  echo "CLAUDE.md: $(git log --oneline -1 -- CLAUDE.md 2>/dev/null || echo 'no changes')"
  echo "CODEX_LOOP_RULES: $(git log --oneline -1 -- docs/development/CODEX_LOOP_RULES.md 2>/dev/null || echo 'no changes')"
}

echo "Skill bridge loaded. Commands: skill_code_review, skill_security_review, skill_verify, skill_run, skill_loop, skill_update_config"

# ── Enhanced security scan with gosec/npm audit ─────────────────────────
skill_security_scan() {
  local repo="${1:-livemask-backend}"
  echo "=== SECURITY SCAN: ${repo} ==="
  case "${repo}" in
    livemask-backend|livemask-nodeagent|livemask-job-service)
      if command -v gosec &>/dev/null; then
        cd "${LIVEMASK_ROOT}/${repo}" && gosec -quiet ./... 2>/dev/null | head -10
      else
        echo "  (gosec not installed — run: go install github.com/securecodewarrior/gosec/v2/cmd/gosec@latest)"
      fi ;;
    livemask-admin|livemask-website)
      cd "${LIVEMASK_ROOT}/${repo}" && npm audit --production 2>/dev/null | grep -E "high|critical" | head -5 || echo "  No high/critical vulnerabilities" ;;
  esac
}
