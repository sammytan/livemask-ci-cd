#!/usr/bin/env bash
# local-verify.sh — Per-repo build, test, lint, and runtime verification.
# Source this, then call verify_repo <repo> to run full verification.
# Outputs structured JSON results for model consumption.
set -euo pipefail

LIVEMASK_ROOT="${LIVEMASK_ROOT:-/Users/sammytan/Developer/LiveMask}"

verify_repo() {
  local repo="${1:-livemask-docs}"
  local repo_dir="${LIVEMASK_ROOT}/${repo}"
  local result_file="/tmp/claude/verify-${repo}-$(date -u +%Y%m%d-%H%M%S).json"
  mkdir -p /tmp/claude

  python3 - "${repo}" "${repo_dir}" "${result_file}" <<'PY'
import json, os, subprocess, sys, pathlib, time

repo = sys.argv[1]
repo_dir = sys.argv[2]
result_file = sys.argv[3]

def run(cmd, cwd=None, timeout=60):
    """Run a command and return (rc, stdout, stderr, duration_sec)."""
    start = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd or repo_dir, text=True,
                          capture_output=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip(), round(time.time()-start, 1)
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s", timeout
    except Exception as e:
        return 1, "", str(e), 0

results = {"repo": repo, "checks": [], "passed": 0, "failed": 0, "skipped": 0}

def add_check(name, cmd, cwd=None, timeout=60, required=True):
    rc, out, err, dur = run(cmd, cwd=cwd, timeout=timeout)
    check = {"name": name, "command": " ".join(cmd), "exit_code": rc,
             "duration_sec": dur, "required": required,
             "stdout_tail": out[-500:] if out else "",
             "stderr_tail": err[-500:] if err else ""}
    if rc == 0:
        check["status"] = "pass"
        if required: results["passed"] += 1
    elif rc == 124:
        check["status"] = "timeout"
        if required: results["failed"] += 1
    else:
        check["status"] = "fail"
        if required: results["failed"] += 1
    results["checks"].append(check)
    return check

# Per-repo verification
r = pathlib.Path(repo_dir)
if not r.exists():
    results["error"] = f"repo directory not found: {repo_dir}"
    pathlib.Path(result_file).write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))
    sys.exit(1)

if repo == "livemask-docs":
    add_check("check-docs", ["bash", "scripts/check-docs.sh"])
    add_check("git-diff-check", ["git", "diff", "--check"])
    add_check("git-status-clean", ["bash", "-c", "test -z \"$(git status --porcelain)\""], required=False)

elif repo == "livemask-ci-cd":
    # Bash syntax check all scripts
    add_check("bash-syntax", ["bash", "-c",
        "find scripts -name '*.sh' -exec bash -n {} \\; 2>&1"])
    add_check("git-diff-check", ["git", "diff", "--check"])
    # Docker compose validation (if available)
    if (r / "infra/docker-compose.local.yml").exists():
        add_check("docker-compose-validate", ["docker", "compose", "-f",
            "infra/docker-compose.local.yml", "config"], required=False)

elif repo == "livemask-backend":
    add_check("go-build", ["go", "build", "./..."], timeout=120)
    add_check("go-vet", ["go", "vet", "./..."], timeout=60)
    add_check("go-test", ["go", "test", "./..."], timeout=180, required=True)
    # Check OpenAPI/Swagger
    if (r / "internal/swagger").exists():
        add_check("swagger-exists", ["bash", "-c",
            "ls internal/swagger/*.yaml 2>/dev/null | head -1"], required=False)
    add_check("git-diff-check", ["git", "diff", "--check"])

elif repo == "livemask-admin":
    if (r / "package.json").exists():
        add_check("npm-install", ["npm", "install", "--prefer-offline"], timeout=120, required=False)
        add_check("npm-build", ["npm", "run", "build"], timeout=180)
        add_check("npm-lint", ["npm", "run", "lint"], timeout=60, required=False)
        add_check("npm-test", ["npm", "test"], timeout=120, required=False)
    add_check("git-diff-check", ["git", "diff", "--check"])

elif repo == "livemask-app":
    if (r / "pubspec.yaml").exists():
        add_check("flutter-analyze", ["flutter", "analyze"], timeout=120)
        add_check("flutter-test", ["flutter", "test"], timeout=120, required=False)
    add_check("git-diff-check", ["git", "diff", "--check"])

elif repo == "livemask-website":
    if (r / "package.json").exists():
        add_check("npm-build", ["npm", "run", "build"], timeout=180, required=False)
    add_check("git-diff-check", ["git", "diff", "--check"])

elif repo == "livemask-nodeagent":
    add_check("go-build", ["go", "build", "./..."], timeout=120)
    add_check("go-vet", ["go", "vet", "./..."], timeout=60)
    add_check("git-diff-check", ["git", "diff", "--check"])

elif repo == "livemask-job-service":
    add_check("go-build", ["go", "build", "./..."], timeout=120)
    add_check("go-vet", ["go", "vet", "./..."], timeout=60)
    add_check("git-diff-check", ["git", "diff", "--check"])

else:
    results["error"] = f"unknown repo: {repo}"

pathlib.Path(result_file).write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
print(f"\nResult: {results['passed']} passed, {results['failed']} failed, {results['skipped']} skipped")
print(f"Full report: {result_file}")
PY
}

# Shortcut: quick check (just git status + basic lint)
verify_quick() {
  local repo="${1:-livemask-docs}"
  local repo_dir="${LIVEMASK_ROOT}/${repo}"
  cd "${repo_dir}" 2>/dev/null || { echo "{\"error\": \"repo not found: ${repo}\"}"; return 1; }

  echo "{"
  echo "  \"repo\": \"${repo}\","
  echo "  \"branch\": \"$(git branch --show-current 2>/dev/null || echo '?')\","
  echo "  \"dirty\": $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo '?'),"
  echo "  \"behind_dev\": $(git rev-list --count HEAD..origin/dev 2>/dev/null || echo '?'),"
  echo "  \"ahead_dev\": $(git rev-list --count origin/dev..HEAD 2>/dev/null || echo '?'),"
  echo "  \"last_commit\": \"$(git log --oneline -1 2>/dev/null || echo '?')\""
  echo "}"
}

# Run verification for the repo a task belongs to
verify_task_repo() {
  local tid="${1:-}"
  [[ -z "${tid}" ]] && { echo "Usage: verify_task_repo <TASK-ID>"; return 1; }

  local repo; repo=$(python3 -c "
import json
ledger = json.load(open('${LIVEMASK_ROOT}/livemask-docs/docs/development/task-state-ledger.json'))
for m in ledger.get('modules',[]):
    for t in m.get('tasks',[]):
        if t.get('task_id') == '${tid}':
            print(t.get('repo',''))
            break
" 2>/dev/null || echo "")

  if [[ -z "${repo}" ]]; then
    echo "{\"error\": \"task ${tid} not found in ledger\"}"
    return 1
  fi

  verify_repo "${repo}"
}

# ── Runtime smoke test ──────────────────────────────────────────────────
verify_runtime() {
  local repo="${1:-livemask-backend}"; local port="${2:-8080}"
  echo "=== RUNTIME SMOKE: ${repo} ==="
  case "${repo}" in
    livemask-backend)
      cd "${LIVEMASK_ROOT}/livemask-backend" 2>/dev/null || return 1
      go build -o /tmp/livemask-backend-test ./... 2>/dev/null && \
      (/tmp/livemask-backend-test &>/dev/null &) && sleep 2 && \
      curl -sSf "http://localhost:${port}/api/v1/health" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'  Health: {d.get(\"status\",\"?\")}')" 2>/dev/null || echo "  (server start failed)"
      pkill -f "livemask-backend-test" 2>/dev/null || true
      ;;
    livemask-admin)
      cd "${LIVEMASK_ROOT}/livemask-admin" 2>/dev/null || return 1
      npm run build 2>&1 | tail -2 && echo "  Admin build: OK" || echo "  Admin build: FAIL"
      ;;
    livemask-app) cd "${LIVEMASK_ROOT}/livemask-app" && flutter analyze 2>&1 | tail -2 ;;
  esac
}

# ── Test coverage analysis ──────────────────────────────────────────────
verify_coverage() {
  local repo="${1:-livemask-backend}"
  case "${repo}" in
    livemask-backend)
      cd "${LIVEMASK_ROOT}/livemask-backend" 2>/dev/null || return 1
      go test -coverprofile=/tmp/coverage.out ./... 2>/dev/null | tail -5
      go tool cover -func=/tmp/coverage.out 2>/dev/null | tail -1 | awk '{print "  Total coverage: "$NF}'
      ;;
    livemask-admin)
      cd "${LIVEMASK_ROOT}/livemask-admin" 2>/dev/null || return 1
      npx jest --coverage 2>/dev/null | grep "All files" | head -1 | awk '{print "  Coverage: "$0}' || echo "  (nyc/jest not configured)"
      ;;
  esac
}
