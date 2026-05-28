#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${REPO_DIR}"

DRIVER="${SCRIPT_DIR}/driver.sh"
PASS=0
FAIL=0

say()  { echo "  [DRIVER] $*"; }
pass() { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }

usage() {
  cat <<'EOF'
Usage:
  bash .claude/skills/run-livemask-ci-cd/driver.sh <command> [args]

Commands:
  validate-all       Run the full validation suite (YAML + workflow contracts + shell + compose).
  validate-yaml       Parse every YAML file in the repo.
  validate-workflows  Validate GitHub Actions workflow contracts (names, triggers, jobs).
  validate-compose    Validate Docker Compose configs (local + staging).
  validate-shell      Run bash -n on all shell scripts.
  validate-dev-ref    Check that service refs are set to dev.

  infra-up [svc]      Start local Docker services (default: postgres,redis).
  infra-down           Stop local Docker services.
  infra-status         Show Docker compose status.

  smoke <name>        Run a single smoke script by name. Use 'list' to see available smokes.

  lint <file>         ShellCheck a single script (requires shellcheck).

  summary              Print results summary (called automatically after validate-all).
EOF
}

# ── YAML validation ──────────────────────────────────────────────────────────

validate_yaml() {
  say "Validating all YAML files..."
  ruby <<'RUBY'
require "yaml"
paths = Dir.glob("**/*.{yml,yaml}", File::FNM_DOTMATCH)
  .reject { |p| p.start_with?(".git/") || p.include?("/node_modules/") }
  .sort
paths.each do |path|
  begin
    YAML.load_file(path)
  rescue Psych::SyntaxError => e
    puts "  [YAML-ERR] #{path}: #{e.message.split("\n").first}"
  rescue => e
    puts "  [YAML-ERR] #{path}: #{e.class}: #{e.message}"
  end
end
RUBY
}

# ── Workflow contract validation ─────────────────────────────────────────────

validate_workflows() {
  say "Validating GitHub workflow contracts..."
  ruby <<'RUBY'
require "yaml"

workflow_contracts = {
  ".github/workflows/staging-smoke.yml" => {
    "name" => "Staging Smoke",
    "on" => ["push", "workflow_dispatch", "repository_dispatch"],
    "jobs" => ["smoke", "notify-lark"],
  },
  ".github/workflows/dev-runtime-deploy.yml" => {
    "name" => "Dev Runtime Deploy",
    "on" => ["push", "workflow_dispatch"],
    "jobs" => ["deploy", "notify-lark"],
  },
  ".github/workflows/auto-task-assignment.yml" => {
    "name" => "Auto Task Assignment",
    "on" => ["workflow_dispatch"],
    "jobs" => ["validate-and-assign"],
  },
  ".github/workflows/app-hysteria2-aar-build.yml" => {
    "name" => "App Hysteria2 AAR Build",
    "on" => ["workflow_dispatch"],
    "jobs" => ["build-aar"],
  },
  ".github/workflows/ci-runner-diagnostics.yml" => {
    "name" => "CI Runner Diagnostics",
    "on" => ["workflow_dispatch"],
    "jobs" => ["runner-ops"],
  },
  ".github/workflows/issue-close-guard.yml" => {
    "name" => "Issue Close Guard",
    "on" => ["workflow_dispatch"],
    "jobs" => ["evaluate"],
  },
  ".github/workflows/issue-sync-strict.yml" => {
    "name" => "Issue Sync Strict Check",
    "on" => ["workflow_dispatch"],
    "jobs" => ["check"],
  },
  ".github/workflows/production-release.yml" => {
    "name" => "Production Release Gate",
    "on" => ["workflow_dispatch", "repository_dispatch"],
    "jobs" => ["release-gate", "notify-lark"],
  },
  ".github/workflows/reusable-docker-build.yml" => {
    "name" => "Reusable Docker Build & Push",
    "on" => ["workflow_call"],
    "jobs" => ["build", "notify-lark"],
  },
  ".github/workflows/reusable-go-build.yml" => {
    "name" => "Reusable Go Build",
    "on" => ["workflow_call"],
    "jobs" => ["build", "notify-lark"],
  },
  ".github/workflows/reusable-cursor-report-dispatch.yml" => {
    "name" => "Reusable Cursor Report Dispatch",
    "on" => ["workflow_call"],
    "jobs" => ["dispatch"],
  },
  ".github/workflows/reusable-cursor-worker-continuation.yml" => {
    "name" => "Reusable Cursor Worker Continuation",
    "on" => ["workflow_call"],
    "jobs" => ["accept-next-task"],
  },
  ".github/workflows/workflow-syntax-guard.yml" => {
    "name" => "Workflow Syntax Guard",
    "on" => ["pull_request", "push", "workflow_dispatch"],
    "jobs" => ["syntax"],
  },
}

errors = 0
workflow_paths = Dir.glob(".github/workflows/*.{yml,yaml}").sort
contract_paths = workflow_contracts.keys.sort

missing = workflow_paths - contract_paths
stale   = contract_paths - workflow_paths
unless missing.empty?
  puts "  [FAIL] Missing workflow contract(s): #{missing.join(", ")}"
  errors += 1
end
unless stale.empty?
  puts "  [FAIL] Contract references missing workflow(s): #{stale.join(", ")}"
  errors += 1
end

workflow_contracts.each do |path, rule|
  data = YAML.load_file(path)
  unless data.is_a?(Hash)
    puts "  [FAIL] #{path}: not a mapping"
    errors += 1
    next
  end

  actual_name = data["name"].to_s
  expected_name = rule["name"]
  if actual_name != expected_name
    puts "  [FAIL] #{path}: expected name #{expected_name.inspect}, got #{actual_name.inspect}"
    errors += 1
  end

  triggers = data["on"] || data[true] || {}
  triggers = {triggers => nil} if triggers.is_a?(String)
  if triggers.is_a?(Hash)
    rule["on"].each do |trigger|
      unless triggers.key?(trigger)
        puts "  [FAIL] #{path}: missing trigger #{trigger.inspect}"
        errors += 1
      end
    end
  else
    puts "  [FAIL] #{path}: missing on trigger mapping"
    errors += 1
  end

  jobs = data["jobs"]
  unless jobs.is_a?(Hash) && !jobs.empty?
    puts "  [FAIL] #{path}: missing or empty jobs mapping"
    errors += 1
    next
  end
  rule["jobs"].each do |job_name|
    unless jobs.key?(job_name)
      puts "  [FAIL] #{path}: missing required job #{job_name.inspect}"
      errors += 1
    end
  end

  jobs.each do |job_name, job|
    unless job.is_a?(Hash)
      puts "  [FAIL] #{path}: job #{job_name.inspect} not a mapping"
      errors += 1
      next
    end
    if job["uses"].to_s.empty?
      unless job.key?("runs-on")
        puts "  [FAIL] #{path}: job #{job_name.inspect} missing runs-on"
        errors += 1
      end
      steps = job["steps"]
      unless steps.is_a?(Array) && !steps.empty?
        puts "  [FAIL] #{path}: job #{job_name.inspect} missing steps"
        errors += 1
      end
    end
  end

  puts "  [OK] #{path}: #{actual_name} (jobs: #{jobs.keys.join(", ")})"
end

exit 1 if errors > 0
RUBY
}

# ── Shell syntax validation ──────────────────────────────────────────────────

validate_shell() {
  say "Checking shell syntax..."
  local errs=0
  local files=()
  for g in scripts/*.sh; do [[ -f "$g" ]] && files+=("$g"); done
  for g in .github/scripts/*.sh; do [[ -f "$g" ]] && files+=("$g"); done
  for f in "${files[@]}"; do
    if bash -n "$f"; then
      echo "  [OK] $f"
    else
      echo "  [FAIL] $f"
      errs=$((errs + 1))
    fi
  done
  return $errs
}

# ── Docker Compose config validation ──────────────────────────────────────────

validate_compose() {
  say "Validating Docker Compose configs..."
  docker compose -f infra/docker-compose.local.yml config > /dev/null && pass "compose local config" || fail "compose local config"
  docker compose -f infra/docker-compose.staging.yml config > /dev/null && pass "compose staging config" || fail "compose staging config"
}

# ── Dev ref validation ────────────────────────────────────────────────────────

validate_dev_ref() {
  say "Validating dev ref guard..."
  bash scripts/validate-dev-ref.sh && pass "validate-dev-ref" || fail "validate-dev-ref"
}

# ── Full validation suite ─────────────────────────────────────────────────────

validate_all() {
  echo "=== Validate: YAML ==="
  validate_yaml && pass "yaml-parse" || fail "yaml-parse"

  echo ""
  echo "=== Validate: Workflow Contracts ==="
  validate_workflows && pass "workflow-contracts" || fail "workflow-contracts"

  echo ""
  echo "=== Validate: Shell Syntax ==="
  validate_shell && pass "shell-syntax" || fail "shell-syntax"

  echo ""
  echo "=== Validate: Docker Compose Configs ==="
  validate_compose || true

  echo ""
  echo "=== Validate: Dev Ref Guard ==="
  validate_dev_ref || true

  summary
}

# ── Infrastructure ────────────────────────────────────────────────────────────

infra_up() {
  local svc="${1:-postgres,redis}"
  say "Starting local services: ${svc}"
  COMPOSE_FILE="${REPO_DIR}/infra/docker-compose.local.yml"
  docker compose -f "${COMPOSE_FILE}" up -d --wait $(echo "$svc" | tr ',' ' ') 2>&1
}

infra_down() {
  say "Stopping local services..."
  COMPOSE_FILE="${REPO_DIR}/infra/docker-compose.local.yml"
  docker compose -f "${COMPOSE_FILE}" down 2>&1
}

infra_status() {
  COMPOSE_FILE="${REPO_DIR}/infra/docker-compose.local.yml"
  docker compose -f "${COMPOSE_FILE}" ps 2>&1
}

# ── Smokes ────────────────────────────────────────────────────────────────────

smoke_list() {
  echo "Available smoke scripts:"
  for f in scripts/*-smoke.sh; do
    [[ -f "$f" ]] || continue
    local name=$(basename "$f" .sh)
    local desc=$(head -5 "$f" | grep -o '# .*' | head -1 | sed 's/^# //' || echo "(no description)")
    printf "  %-45s %s\n" "$name" "$desc"
  done
}

smoke_run() {
  local name="$1"
  local script="scripts/${name}.sh"
  if [[ ! -f "$script" ]]; then
    echo "Unknown smoke: ${name}"
    echo "Use 'list' to see available smokes."
    return 1
  fi
  say "Running smoke: ${name}"
  bash "$script" && pass "$name" || fail "$name"
}

# ── Lint ──────────────────────────────────────────────────────────────────────

lint_script() {
  local file="$1"
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck not installed. Install: brew install shellcheck"
    return 1
  fi
  shellcheck -x "$file"
}

# ── Summary ───────────────────────────────────────────────────────────────────

summary() {
  echo ""
  echo "============================================"
  echo " Results: ${PASS} passed, ${FAIL} failed"
  echo "============================================"
  if [[ $FAIL -gt 0 ]]; then
    return 1
  fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

command="${1:-}"
shift || true

case "$command" in
  validate-all)       validate_all "$@";;
  validate-yaml)      validate_yaml "$@";;
  validate-workflows) validate_workflows "$@";;
  validate-compose)   validate_compose "$@";;
  validate-shell)     validate_shell "$@";;
  validate-dev-ref)   validate_dev_ref "$@";;
  infra-up)           infra_up "$@";;
  infra-down)         infra_down "$@";;
  infra-status)       infra_status "$@";;
  smoke)
    sub="${1:-list}"
    shift || true
    case "$sub" in
      list) smoke_list;;
      *)    smoke_run "$sub";;
    esac
    ;;
  lint)               lint_script "$@";;
  summary)            summary "$@";;
  help|--help|-h)     usage;;
  *)
    echo "Unknown command: ${command}"
    usage
    exit 1
    ;;
esac
