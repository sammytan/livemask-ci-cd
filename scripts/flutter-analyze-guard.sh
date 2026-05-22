#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# TASK-CICD-APP-FLUTTER-ANALYZE-GUARD-001
# Flutter Analyze Guard — Wrapper with --no-fatal-infos
# ═══════════════════════════════════════════════════════════════════════════════
# Runs `flutter analyze` with --no-fatal-infos by default so that info-level
# lints (e.g. unused_import in certain generated files) do not block CI.
#
# Usage:
#   bash scripts/flutter-analyze-guard.sh [--fatal-infos] [additional args]
#
#   --fatal-infos: opt-in to treat infos as fatal (default: off)
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FATAL_INFOS=false
EXTRA_ARGS=()

for arg in "$@"; do
  if [[ "${arg}" == "--fatal-infos" ]]; then
    FATAL_INFOS=true
  else
    EXTRA_ARGS+=("${arg}")
  fi
done

# Detect the flutter project root
FLUTTER_DIR="${FLUTTER_DIR:-}"
if [[ -z "${FLUTTER_DIR}" ]]; then
  # Check common locations
  for candidate in "${REPO_DIR}" "${REPO_DIR}/.." "${REPO_DIR}/../livemask-app"; do
    if [[ -f "${candidate}/pubspec.yaml" ]]; then
      FLUTTER_DIR="${candidate}"
      break
    fi
  done
fi

if [[ -z "${FLUTTER_DIR}" ]]; then
  echo "ERROR: Cannot find Flutter project root (no pubspec.yaml found)."
  echo "  Set FLUTTER_DIR env var or run from a repo containing pubspec.yaml."
  echo "  Searched: ${REPO_DIR}, ${REPO_DIR}/.., ${REPO_DIR}/../livemask-app"
  exit 1
fi

echo "=== Flutter Analyze Guard (TASK-CICD-APP-FLUTTER-ANALYZE-GUARD-001) ==="
echo "  Flutter dir: ${FLUTTER_DIR}"
echo "  Fatal infos: ${FATAL_INFOS}"
echo "  Extra args: ${EXTRA_ARGS[*]:-none}"
echo ""

cd "${FLUTTER_DIR}"

FLUTTER_CMD=(flutter analyze)

if [[ "${FATAL_INFOS}" == "false" ]]; then
  FLUTTER_CMD+=(--no-fatal-infos)
fi

if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  FLUTTER_CMD+=("${EXTRA_ARGS[@]}")
fi

echo "Running: ${FLUTTER_CMD[*]}"
echo ""

if "${FLUTTER_CMD[@]}"; then
  echo ""
  echo "[TASK-CICD-APP-FLUTTER-ANALYZE-GUARD-001] PASSED."
else
  ANALYZE_RC=$?
  echo ""
  echo "[TASK-CICD-APP-FLUTTER-ANALYZE-GUARD-001] FAILED (exit code ${ANALYZE_RC})."
  exit ${ANALYZE_RC}
fi
