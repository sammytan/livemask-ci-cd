#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:${LIVEMASK_BACKEND_HTTP_PORT:-18080}}"
API_CASES_FILE="${API_CASES_FILE:-${SCRIPT_DIR}/api-smoke-cases.tsv}"
CURL_TIMEOUT_SECONDS="${CURL_TIMEOUT_SECONDS:-8}"
API_WAIT_SECONDS="${API_WAIT_SECONDS:-60}"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/api-smoke.sh

Environment:
  API_BASE_URL           Backend base URL. Default: http://127.0.0.1:${LIVEMASK_BACKEND_HTTP_PORT:-18080}
  API_CASES_FILE         TSV test cases file. Default: scripts/api-smoke-cases.tsv
  CURL_TIMEOUT_SECONDS   Per-request timeout. Default: 8
  API_WAIT_SECONDS       Wait for Backend before tests. Default: 60

Case file columns:
  name<TAB>method<TAB>path<TAB>expected_status<TAB>assertions

Assertion examples:
  json.status=ok
  json.db_connected=true
  json.config_version>=1
  json.config_hash~^sha256:
  json.configs.length>=2
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -f "${API_CASES_FILE}" ]]; then
  echo "API cases file not found: ${API_CASES_FILE}" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

assert_json() {
  local body_file="$1"
  local assertion="$2"
  python3 - "$body_file" "$assertion" <<'PY'
import json
import re
import sys

body_file, assertion = sys.argv[1], sys.argv[2]
with open(body_file, "r", encoding="utf-8") as fh:
    data = json.load(fh)

if not assertion.startswith("json."):
    raise SystemExit(f"unsupported assertion: {assertion}")

expr = assertion[len("json."):]
op = None
for candidate in (">=", "<=", "!=", "=", ">", "<", "~"):
    if candidate in expr:
        op = candidate
        left, right = expr.split(candidate, 1)
        break
if op is None:
    raise SystemExit(f"unsupported assertion operator: {assertion}")

def convert_expected(raw):
    value = raw.strip()
    if value == "true":
        return True
    if value == "false":
        return False
    if value == "null":
        return None
    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value

def lookup(obj, path):
    current = obj
    for part in path.split("."):
        if part == "length":
            current = len(current)
            continue
        if isinstance(current, dict):
            if part not in current:
                raise KeyError(part)
            current = current[part]
        elif isinstance(current, list):
            current = current[int(part)]
        else:
            raise KeyError(part)
    return current

actual = lookup(data, left.strip())
expected = convert_expected(right)

ok = False
if op == "=":
    ok = actual == expected
elif op == "!=":
    ok = actual != expected
elif op == "~":
    ok = re.search(str(expected), str(actual)) is not None
elif op == ">=":
    ok = float(actual) >= float(expected)
elif op == "<=":
    ok = float(actual) <= float(expected)
elif op == ">":
    ok = float(actual) > float(expected)
elif op == "<":
    ok = float(actual) < float(expected)

if not ok:
    raise SystemExit(f"{assertion} failed: actual={actual!r}")
PY
}

echo "=== LiveMask API Smoke ==="
echo "Base URL: ${API_BASE_URL}"
echo "Cases:    ${API_CASES_FILE}"
echo

if [[ "${API_WAIT_SECONDS}" -gt 0 ]]; then
  echo "Waiting for Backend API for up to ${API_WAIT_SECONDS}s..."
  ready=false
  for _ in $(seq 1 "${API_WAIT_SECONDS}"); do
    if curl -fsS --max-time 2 "${API_BASE_URL}/api/v1/health" >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "${ready}" != "true" ]]; then
    echo "Backend API is not reachable: ${API_BASE_URL}" >&2
    echo
  fi
fi

failed=0
total=0

while IFS=$'\t' read -r name method path expected_status assertions || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" ]] && continue
  [[ "${name}" == \#* ]] && continue

  total=$((total + 1))
  url="${API_BASE_URL}${path}"
  body_file="${tmp_dir}/case-${total}.json"
  status_file="${tmp_dir}/case-${total}.status"

  echo "--- ${name} ---"
  echo "${method} ${url}"
  case_failed=0

  status="$(curl -sS \
    --max-time "${CURL_TIMEOUT_SECONDS}" \
    -X "${method}" \
    -H "Accept: application/json" \
    -o "${body_file}" \
    -w "%{http_code}" \
    "${url}" 2>"${tmp_dir}/case-${total}.curl.err" || true)"
  printf '%s' "${status}" >"${status_file}"

  if [[ "${status}" != "${expected_status}" ]]; then
    echo "FAIL: status=${status}, expected=${expected_status}"
    if [[ -s "${tmp_dir}/case-${total}.curl.err" ]]; then
      cat "${tmp_dir}/case-${total}.curl.err"
    fi
    cat "${body_file}" 2>/dev/null || true
    failed=1
    case_failed=1
    echo
    continue
  fi

  if [[ -s "${body_file}" ]]; then
    python3 -m json.tool "${body_file}" 2>/dev/null || cat "${body_file}"
  else
    echo "(empty body)"
  fi

  IFS=';' read -r -a assertion_list <<<"${assertions:-}"
  for assertion in "${assertion_list[@]}"; do
    [[ -z "${assertion}" ]] && continue
    if ! assert_json "${body_file}" "${assertion}"; then
      failed=1
      case_failed=1
    fi
  done

  if [[ "${case_failed}" -eq 0 ]]; then
    echo "PASS"
  fi
  echo
done <"${API_CASES_FILE}"

if [[ "${total}" -eq 0 ]]; then
  echo "No API smoke cases found." >&2
  exit 1
fi

if [[ "${failed}" -eq 1 ]]; then
  echo "API smoke FAILED (${total} cases)."
  echo
  echo "Hint:"
  echo "  Start backend first, regardless of local process or Docker:"
  echo "    cd ${REPO_DIR}"
  echo "    bash scripts/runtime.sh start --mode local --services backend"
  echo
  echo "  Or point to another Backend:"
  echo "    API_BASE_URL=http://host:port bash scripts/api-smoke.sh"
  exit 1
fi

echo "API smoke PASS (${total} cases)."
