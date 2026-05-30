#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# TASK-CICD-DOCKER-BUILD-PRIVATE-REPO-001
#
# Prepares infra/_build_deps/ directories for staging Docker builds.
# Provides source code to Dockerfiles via local build context,
# eliminating the need for git clone/fetch inside Dockerfiles.
#
# CI workflow:
#   1. actions/checkout@v4 places repo source into infra/_build_deps/<name>/
#   2. This script runs with --ci to create .exists markers
#   3. docker compose build succeeds via local COPY
#
# Local dev:
#   1. This script copies source from LIVEMASK_WORKSPACE_ROOT (e.g. ~/Developer/LiveMask)
#   2. docker compose build succeeds via local COPY
#
# Usage:
#   bash scripts/prepare-staging-build-context.sh [--workspace PATH] [--ci]
#
# Options:
#   --workspace PATH   LiveMask workspace root (default: $LIVEMASK_WORKSPACE_ROOT or ~/Developer/LiveMask)
#   --ci               CI mode: only create .exists markers, don't copy source (use with actions/checkout)
#   --help             Show this help
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="${LIVEMASK_WORKSPACE_ROOT:-$HOME/Developer/LiveMask}"
BUILD_DEPS="${REPO_ROOT}/infra/_build_deps"
CI_MODE=false

# Map rows: build-dest dir | workspace repo name
REPO_ROWS="
backend|livemask-backend
admin|livemask-admin
website|livemask-website
job-service|livemask-job-service
nodeagent|livemask-nodeagent
"

# ============================================================
# Parse args
# ============================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      WORKSPACE_ROOT="${2:-}"
      shift 2
      ;;
    --ci)
      CI_MODE=true
      shift
      ;;
    --help|-h)
      sed -n '3,/^# =/p' "${BASH_SOURCE[0]}" | sed 's/^# //;s/^#$//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# ============================================================
# Main
# ============================================================

echo "[prepare] Preparing staging build context at: ${BUILD_DEPS}"
mkdir -p "${BUILD_DEPS}"

printf "%s" "${REPO_ROWS}" | while IFS='|' read -r dir_name repo_name; do
  [[ -z "${dir_name}" ]] && continue
  target="${BUILD_DEPS}/${dir_name}"

  if [[ "${CI_MODE}" == "true" ]]; then
    # CI mode: actions/checkout placed source files.
    # If go.mod exists, the checkout succeeded — just ensure .exists.
    # If not, create .exists as a stub (but workflow should have checked out).
    mkdir -p "${target}"
    if [[ -f "${target}/go.mod" || -f "${target}/package.json" ]]; then
      echo "[prepare]  [CI] ${target} — source from checkout found"
    else
      echo "[prepare]  [CI] ${target} — no go.mod/package.json (checkout may be missing), creating stub"
    fi
    touch "${target}/.exists"
    continue
  fi

  # Local dev mode: copy from workspace repos, or create stub
  ws_repo="${WORKSPACE_ROOT}/${repo_name}"
  if [[ -d "${ws_repo}" ]]; then
    echo "[prepare]  [workspace] ${ws_repo} → ${target}"
    mkdir -p "${target}"
    # Use rsync or cp to copy source, excluding VCS/dependency/build caches.
    # Do not rm -rf the target first: local Docker builds may have left
    # root-owned cache directories under infra/_build_deps.
    rsync -a --delete \
      --exclude='.git' \
      --exclude='.cache' \
      --exclude='.gomodcache' \
      --exclude='node_modules' \
      --exclude='.next' \
      --exclude='dist' \
      --exclude='build' \
      "${ws_repo}/" "${target}/" 2>/dev/null || \
      cp -a "${ws_repo}/" "${target}/"
    touch "${target}/.exists"
  else
    echo "[prepare]  [warn] ${repo_name} not found at ${ws_repo}; creating stub"
    mkdir -p "${target}"
    cat > "${target}/.no-source" <<-STUB_EOF
		# This directory is a stub. Source was not available.
		# Run scripts/prepare-staging-build-context.sh with the correct --workspace,
		# or ensure the repo exists at: ${ws_repo}
		# 
		# In CI, actions/checkout should place source here before running compose build.
		STUB_EOF
    touch "${target}/.exists"
  fi
done

# Always ensure .exists at the dir root so compose file validation never fails
touch "${BUILD_DEPS}/.exists"

echo "[prepare] Build context prepared. Contents:"
find "${BUILD_DEPS}" -maxdepth 2 \
  \( -name '.exists' -o -name 'go.mod' -o -name '.no-source' \) \
  | sort | sed 's/^/  /'
echo "[prepare] Done."
