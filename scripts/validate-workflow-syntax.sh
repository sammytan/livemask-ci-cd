#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

echo "=== Validate all YAML files ==="
ruby <<'RUBY'
require "yaml"

paths = Dir.glob("**/*.{yml,yaml}", File::FNM_DOTMATCH).reject do |path|
  path.start_with?(".git/") ||
    path.start_with?(".worktrees/") ||
    path.start_with?(".cursor-worker/") ||
    path.start_with?("infra/_build_deps/")
end.sort

abort("No YAML files found") if paths.empty?

paths.each do |path|
  data = YAML.load_file(path)
  abort("#{path}: YAML parsed to nil") if data.nil?
  puts "#{path}: YAML parse OK"
end
RUBY

echo
echo "=== Validate GitHub workflow contracts ==="
ruby <<'RUBY'
require "yaml"

workflow_contracts = {
  ".github/workflows/staging-smoke.yml" => {
    "name" => "Staging Smoke",
    "on" => ["workflow_dispatch"],
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

workflow_paths = Dir.glob(".github/workflows/*.{yml,yaml}").sort
contract_paths = workflow_contracts.keys.sort

missing_contracts = workflow_paths - contract_paths
stale_contracts = contract_paths - workflow_paths
abort("Missing workflow contract(s): #{missing_contracts.join(", ")}") unless missing_contracts.empty?
abort("Contract references missing workflow(s): #{stale_contracts.join(", ")}") unless stale_contracts.empty?

workflow_contracts.each do |path, rule|
  data = YAML.load_file(path)
  abort("#{path}: workflow YAML did not parse to a mapping") unless data.is_a?(Hash)

  actual_name = data["name"].to_s
  expected_name = rule["name"]
  abort("#{path}: expected name #{expected_name.inspect}, got #{actual_name.inspect}") unless actual_name == expected_name

  triggers = data["on"] || data[true] || {}
  triggers = {triggers => nil} if triggers.is_a?(String)
  abort("#{path}: missing on trigger mapping") unless triggers.is_a?(Hash)
  rule["on"].each do |trigger|
    abort("#{path}: missing required trigger #{trigger.inspect}") unless triggers.key?(trigger)
  end

  jobs = data["jobs"]
  abort("#{path}: missing jobs mapping") unless jobs.is_a?(Hash) && !jobs.empty?
  rule["jobs"].each do |job_name|
    abort("#{path}: missing required job #{job_name.inspect}") unless jobs.key?(job_name)
  end

  jobs.each do |job_name, job|
    abort("#{path}: job #{job_name.inspect} must be a mapping") unless job.is_a?(Hash)
    if job["uses"].to_s.empty?
      abort("#{path}: job #{job_name.inspect} missing runs-on") unless job.key?("runs-on")
      steps = job["steps"]
      abort("#{path}: job #{job_name.inspect} missing steps") unless steps.is_a?(Array) && !steps.empty?
    end
  end

  puts "#{path}: #{actual_name} contract OK (triggers: #{rule["on"].join(", ")}, jobs: #{jobs.keys.join(", ")})"
end
RUBY

echo
echo "=== Validate Docker compose configs ==="
docker compose -f infra/docker-compose.staging.yml config >/tmp/livemask-staging-compose.yml
docker compose -f infra/docker-compose.local.yml config >/tmp/livemask-local-compose.yml

echo
echo "=== Validate shell syntax ==="
bash -n .github/scripts/*.sh scripts/*.sh

echo
echo "Workflow syntax guard PASS"
