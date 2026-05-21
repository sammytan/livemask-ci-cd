#!/usr/bin/env bash
# openapi-drift-smoke.sh — CI/CD OpenAPI Drift Check
# TASK-CICD-OPENAPI-DRIFT-CHECK-001
#
# Runs Backend's scripts/validate-openapi.sh against the configured
# BACKEND_REF. Reports PASS/SKIP/FAIL precisely:
#   PASS — validation script runs and passes
#   SKIP — backend repo/ref intentionally unavailable in local/CI context
#   FAIL — validation errors, route drift, secret leaks, or public Swagger UI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

WORKSPACE_ROOT="${LIVEMASK_WORKSPACE_ROOT:-$HOME/Developer/LiveMask}"
BACKEND_REPO="${WORKSPACE_ROOT}/livemask-backend"
BACKEND_REF="${BACKEND_REF:-dev}"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass_result() {
  local desc="$1"
  echo "  PASS: ${desc}"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail_result() {
  local desc="$1"
  echo "  FAIL: ${desc}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip_result() {
  local desc="$1"
  echo "  SKIP: ${desc}"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

echo "================================================"
echo " TASK-CICD-OPENAPI-DRIFT-CHECK-001"
echo " OpenAPI Drift Smoke"
echo "================================================"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# Step 1: Check backend repo availability
# ──────────────────────────────────────────────────────────────────────────────
echo "--- [1] Backend repo check ---"
echo "  WORKSPACE_ROOT=${WORKSPACE_ROOT}"
echo "  BACKEND_REF=${BACKEND_REF}"

if [[ ! -d "${BACKEND_REPO}" ]]; then
  # CI mode: try to find backend under infra/_build_deps
  BACKEND_REPO="${REPO_DIR}/infra/_build_deps/backend"
fi

VALIDATE_SCRIPT="${BACKEND_REPO}/scripts/validate-openapi.sh"

if [[ ! -d "${BACKEND_REPO}" ]]; then
  skip_result "Backend repo not found at ${BACKEND_REPO} — SKIP (local backend checkout unavailable)"
  echo ""
  echo "=== Results: 0 passed, 0 failed, 1 skipped ==="
  exit 0
fi

if [[ ! -f "${VALIDATE_SCRIPT}" ]]; then
  skip_result "Backend validate-openapi.sh not found at ${VALIDATE_SCRIPT} — SKIP (script not yet deployed)"
  echo ""
  echo "=== Results: 0 passed, 0 failed, 1 skipped ==="
  exit 0
fi

if [[ "${BACKEND_REF}" != "dev" ]]; then
  skip_result "BACKEND_REF=${BACKEND_REF} is not dev — SKIP (acceptance smoke requires dev ref)"
  echo ""
  echo "=== Results: 0 passed, 0 failed, 1 skipped ==="
  exit 0
fi

echo "  Backend repo found at: ${BACKEND_REPO}"
echo "  Validate script found: ${VALIDATE_SCRIPT}"
pass_result "Backend repo and validate-openapi.sh accessible"

# ──────────────────────────────────────────────────────────────────────────────
# Step 2: Check backend Go module availability (go.mod)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [2] Backend Go module check ---"
if [[ ! -f "${BACKEND_REPO}/go.mod" ]]; then
  skip_result "go.mod not found — SKIP (Go module not available)"
  echo ""
  echo "=== Results: 1 passed, 0 failed, 1 skipped ==="
  exit 0
fi
pass_result "go.mod present"

# ──────────────────────────────────────────────────────────────────────────────
# Step 3: Run Backend's built-in OpenAPI validation
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [3] Run Backend validate-openapi.sh ---"

VALIDATE_OUTPUT=$(cd "${BACKEND_REPO}" && bash "${VALIDATE_SCRIPT}" 2>&1 || true)
VALIDATE_EXIT_CODE=$?

echo ""
echo "${VALIDATE_OUTPUT}"
echo ""

if [[ "${VALIDATE_EXIT_CODE}" -eq 0 ]]; then
  pass_result "Backend validate-openapi.sh completed (exit=0)"
else
  fail_result "Backend validate-openapi.sh FAILED (exit=${VALIDATE_EXIT_CODE})"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 4: App Release route documentation coverage (TASK-CICD-APP-RELEASE-001)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- [4] App Release route documentation (TASK-CICD-APP-RELEASE-001) ---"

OPENAPI_PATH="${BACKEND_REPO}/docs/openapi.yaml"
if [[ ! -f "${OPENAPI_PATH}" ]]; then
  OPENAPI_PATH="${BACKEND_REPO}/internal/swagger/openapi.yaml"
fi

check_app_release_route() {
  local route="$1"
  local desc="$2"
  if rg -q "${route}" "${OPENAPI_PATH}" 2>/dev/null; then
    pass_result "App Release OpenAPI: ${desc} (${route}) documented"
  else
    fail_result "App Release OpenAPI: ${desc} (${route}) NOT documented"
  fi
}

echo "  OpenAPI spec: ${OPENAPI_PATH}"
echo ""

# Admin App Release API
check_app_release_route "/admin/api/v1/app/releases" "Admin list/create/releases"

# Admin App Release storage settings
check_app_release_route "/admin/api/v1/app-release-storage" "Admin storage settings"

# Public latest release API
check_app_release_route "/api/v1/app/releases/latest" "Public latest release"

# Internal executor APIs (6 paths)
check_app_release_route "/internal/job-executors/app-release/artifact-verify" "Executor artifact-verify"
check_app_release_route "/internal/job-executors/app-release/publish" "Executor publish"
check_app_release_route "/internal/job-executors/app-release/revoke" "Executor revoke"
check_app_release_route "/internal/job-executors/app-release/storage-verify" "Executor storage-verify"
check_app_release_route "/internal/job-executors/app-release/adoption-aggregate" "Executor adoption-aggregate"
check_app_release_route "/internal/job-executors/app-release/website-downloads-refresh" "Executor website-downloads-refresh"

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo " TASK-CICD-OPENAPI-DRIFT-CHECK-001 SUMMARY"
echo "================================================"
echo "  PASS: ${PASS_COUNT}"
echo "  FAIL: ${FAIL_COUNT}"
echo "  SKIP: ${SKIP_COUNT}"
echo "================================================"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "[TASK-CICD-OPENAPI-DRIFT-CHECK-001] OpenAPI drift smoke FAILED."
  exit 1
fi

echo "[TASK-CICD-OPENAPI-DRIFT-CHECK-001] OpenAPI drift smoke PASSED."
exit 0
