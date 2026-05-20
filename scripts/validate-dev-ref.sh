#!/usr/bin/env bash
set -euo pipefail

# TASK-RULES-CICD-DEV-REF-001
# CI/CD acceptance smoke must validate the integrated dev branch. A task branch
# can run local/unit prechecks, but cannot be used as final smoke evidence.

checked_any=false

check_ref() {
  local name="$1"
  local value="${!name:-dev}"

  checked_any=true

  if [[ -z "${value}" ]]; then
    value="dev"
  fi

  if [[ "${value}" != "dev" ]]; then
    echo "ERROR: ${name} must be dev for CI/CD smoke validation, got '${value}'." >&2
    echo "Merge the task branch into dev, push origin/dev, then run smoke against dev." >&2
    exit 2
  fi
}

for ref_name in \
  BACKEND_REF \
  ADMIN_REF \
  APP_REF \
  WEBSITE_REF \
  NODEAGENT_REF \
  JOB_SERVICE_REF
do
  check_ref "${ref_name}"
done

if [[ "${GITHUB_REF_NAME:-dev}" != "dev" && "${GITHUB_EVENT_NAME:-}" != "release" ]]; then
  echo "ERROR: CI/CD smoke must run from dev, got GITHUB_REF_NAME='${GITHUB_REF_NAME}'." >&2
  exit 2
fi

if [[ "${checked_any}" == "true" ]]; then
  echo "Dev-only smoke ref guard PASS."
fi
