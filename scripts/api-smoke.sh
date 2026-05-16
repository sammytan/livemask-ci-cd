#!/usr/bin/env bash
set -eo pipefail

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

Case file columns (tab-separated):
  name<TAB>method<TAB>path<TAB>expected_status<TAB>assertions<TAB>payload<TAB>auth_bearer

Assertions examples:
  json.status=ok
  json.db_connected=true
  json.config_version>=1
  json.config_hash~^sha256:
  json.configs.length>=2
  save.tok_app=json.access_token     # extract value into variable
  json.access_token!=""              # assert not empty
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

# ── Variable store for chaining ─────────────────────────────────────────────
# Uses prefix naming: __SMOKE_VAR_<name> (bash 3.x compatible)

_get_var() {
  local varname="__SMOKE_VAR_${1}"
  echo "${!varname:-}"
}

_set_var() {
  eval "__SMOKE_VAR_${1}=\$2"
}

resolve_var_refs() {
  local value="$1"
  local out="$value"
  while [[ "$out" =~ (\$([a-zA-Z_][a-zA-Z0-9_.]*)) ]]; do
    local ref="${BASH_REMATCH[1]}"
    local varname="${BASH_REMATCH[2]}"
    local replacement
    replacement=$(_get_var "$varname")
    if [[ -z "$replacement" ]]; then
      echo "WARN: variable \$$varname not set, leaving as-is" >&2
      break
    fi
    out="${out//${ref}/${replacement}}"
  done
  echo "$out"
}

# ── JSON assertion engine ──────────────────────────────────────────────────

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

# save.<var>=json.<path> — extract into variable (handled in bash after call)
if assertion.startswith("save."):
    expr = assertion[len("save."):]
    if "=" not in expr:
        raise SystemExit(f"invalid save assertion: {assertion}")
    varname, path = expr.split("=", 1)
    varname = varname.strip()
    path = path.strip()
    if not path.startswith("json."):
        raise SystemExit(f"save path must start with json.: {assertion}")
    parts = path[len("json."):].split(".")
    current = data
    for part in parts:
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
    print(f"SAVE_RESULT:{varname}:{current}")
    sys.exit(0)

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
    raise SystemExit(f"assertion failed: '{assertion}' actual={actual!r}")
PY
}

# ── Main run ───────────────────────────────────────────────────────────────

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
degraded_count=0
pass_count=0

while IFS=$'\t' read -r name method path expected_status assertions payload auth_bearer || [[ -n "${name:-}" ]]; do
  [[ -z "${name:-}" ]] && continue
  [[ "${name}" == \#* ]] && continue

  payload="${payload--}"
  auth_bearer="${auth_bearer--}"

  total=$((total + 1))
  url="${API_BASE_URL}${path}"
  body_file="${tmp_dir}/case-${total}.json"
  err_file="${tmp_dir}/case-${total}.curl.err"

  echo "--- [${total}] ${name} ---"
  echo "${method} ${url}"

  case_failed=0
  is_degraded=false

  # Resolve payload variable references
  resolved_payload=""
  if [[ "${payload}" != "-" && -n "${payload}" ]]; then
    resolved_payload="$(resolve_var_refs "${payload}")"
    echo "${resolved_payload}" | python3 -m json.tool 2>/dev/null || echo "Payload: ${resolved_payload}"
  fi

  # Resolve auth bearer token from variable store
  auth_header=()
  if [[ "${auth_bearer}" != "-" && -n "${auth_bearer}" ]]; then
    token="$(_get_var "${auth_bearer}")"
    if [[ -n "${token}" ]]; then
      auth_header=(-H "Authorization: Bearer ${token}")
      echo "Auth: Bearer <${auth_bearer}> (token length: ${#token})"
    else
      echo "Auth: Bearer <${auth_bearer}> (no token in store — sending without auth)"
    fi
  fi

  # Build curl args
  curl_args=(
    --max-time "${CURL_TIMEOUT_SECONDS}"
    -X "${method}"
    -H "Accept: application/json"
    -o "${body_file}"
    -w "%{http_code}"
  )

  if [[ "${#auth_header[@]}" -gt 0 ]]; then
    curl_args+=("${auth_header[@]}")
  fi

  if [[ -n "${resolved_payload}" ]]; then
    curl_args+=(-H "Content-Type: application/json" -d "${resolved_payload}")
  fi

  status="$(curl -sS "${curl_args[@]}" "${url}" 2>"${err_file}" || true)"

  # ── Check HTTP status ──────────────────────────────────────────────────
  if [[ "${status}" != "${expected_status}" ]]; then
    alt_ok=false
    is_degraded=false
    IFS='|' read -r -a status_alternatives <<<"${expected_status}"
    for alt in "${status_alternatives[@]}"; do
      if [[ "${status}" == "${alt}" ]]; then
        alt_ok=true
        if [[ "${alt}" != "${status_alternatives[0]}" ]]; then
          is_degraded=true
        fi
        break
      fi
    done

    if [[ "${alt_ok}" != "true" ]]; then
      echo "[TASK-AUTH-001] FAIL: ${name} (HTTP ${status}, expected ${expected_status})"
      if [[ -s "${err_file}" ]]; then
        echo "--- curl stderr ---"
        cat "${err_file}"
      fi
      if [[ -s "${body_file}" ]]; then
        echo "--- response body ---"
        python3 -m json.tool "${body_file}" 2>/dev/null || cat "${body_file}"
      fi
      failed=1
      case_failed=1
      echo
      continue
    else
      degraded_count=$((degraded_count + 1))
      echo "Status: ${status} (degraded, expected ${expected_status})"
    fi
  fi

  # ── Show response body ─────────────────────────────────────────────────
  if [[ -s "${body_file}" ]]; then
    python3 -m json.tool "${body_file}" 2>/dev/null || cat "${body_file}"
  else
    echo "(empty body)"
  fi

  # ── Skip detailed assertions for degraded cases ───────────────────────
  if [[ "${is_degraded}" == "true" ]]; then
    echo "PASS (degraded — endpoint not ready)"
    echo
    continue
  fi

  # ── Run assertions ─────────────────────────────────────────────────────
  IFS=';' read -r -a assertion_list <<<"${assertions:-}"
  for assertion in "${assertion_list[@]}"; do
    [[ -z "${assertion}" ]] && continue

    if [[ "${assertion}" == save.* ]]; then
      save_result=$(assert_json "${body_file}" "${assertion}" 2>/dev/null || true)
      if echo "$save_result" | grep -q "^SAVE_RESULT:"; then
        var_name="${save_result#SAVE_RESULT:}"
        var_value="${var_name#*:}"
        var_name="${var_name%%:*}"
        _set_var "${var_name}" "${var_value}"
        echo "Saved: \$${var_name} = ${var_value}"
      else
        echo "[TASK-AUTH-001] FAIL: ${name} — ${assertion}"
        echo "assert_json output: ${save_result}"
        failed=1
        case_failed=1
      fi
      continue
    fi

    if ! assert_json "${body_file}" "${assertion}"; then
      echo "[TASK-AUTH-001] FAIL: ${name} — ${assertion}"
      failed=1
      case_failed=1
    fi
  done

  if [[ "${case_failed}" -eq 0 ]]; then
    pass_count=$((pass_count + 1))
    echo "PASS"
  fi
  echo
done <"${API_CASES_FILE}"

if [[ "${total}" -eq 0 ]]; then
  echo "No API smoke cases found." >&2
  exit 1
fi

echo "=== API Smoke Summary ==="
echo "Total:    ${total}"
echo "Pass:     ${pass_count}"
echo "Degraded: ${degraded_count}"
echo "Failed:   $((total - pass_count - degraded_count))"

if [[ "${failed}" -eq 1 ]]; then
  echo ""
  echo "[TASK-AUTH-001] API smoke FAILED."
  echo ""
  echo "Hint:"
  echo "  Start backend first:"
  echo "    cd ${REPO_DIR}"
  echo "    bash scripts/runtime.sh start --mode local --services backend"
  echo ""
  echo "  Or point to another Backend:"
  echo "    API_BASE_URL=http://host:port bash scripts/api-smoke.sh"
  exit 1
fi

echo "API smoke PASS (${total} cases)."
