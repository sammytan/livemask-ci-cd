#!/usr/bin/env bash
set -euo pipefail

# TASK-CICD-DEV-MERGE-GUARD-001
# Guarded one-task-at-a-time merge flow for LiveMask repositories.

LIVEMASK_WORKSPACE_ROOT="${LIVEMASK_WORKSPACE_ROOT:-$HOME/Developer/LiveMask}"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/dev-merge-guard.sh --repo PATH --task-branch BRANCH --task-id TASK-XXXX [options]
  bash scripts/dev-merge-guard.sh task/branch-name

Required:
  --repo PATH              Target repository path.
  --task-branch BRANCH     One task branch to merge. Batch branch lists are rejected.
  --task-id TASK-XXXX      Task ID used in rescue/integration branch names and reports.

Options:
  --validation-cmd CMD     Validation command to run. May be repeated.
                           If omitted, a repo-specific default is used.
  --push                   Push dev to origin/dev after dev validation passes.
                           Without --push, the script stops after integration validation.
  --dry-run                Run preflight checks only; do not merge.
  --allow-local-branch     Allow a task branch without an origin/<branch> backup.
                           Default is fail-closed and requires remote backup.
  --help                   Show this help.

Rules:
  - Merges exactly one task branch.
  - The legacy one-argument form infers --repo from cwd and --task-id from
    changed docs/development/tasks/TASK-*.md files or the branch commit subject.
  - Refuses dirty worktrees and in-progress merge/rebase/cherry-pick states.
  - Creates rescue/<repo>-dev-before-<TASK>-<timestamp> from origin/dev.
  - Tests merge on integration/<TASK>-<timestamp> before touching dev.
  - Re-runs validation on dev before push.
  - Never force-pushes and never merges task branches directly into main.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

info() {
  echo "[dev-merge-guard] $*"
}

repo=""
task_branch=""
task_id=""
push_dev=false
dry_run=false
allow_local_branch=false
validation_cmds=()

legacy_single_branch=""
if [[ $# -eq 1 && "${1:-}" == task/* ]]; then
  legacy_single_branch="$1"
  repo="$(pwd -P)"
  task_branch="${legacy_single_branch}"
  push_dev=true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --task-branch)
      task_branch="${2:-}"
      shift 2
      ;;
    --task-id)
      task_id="${2:-}"
      shift 2
      ;;
    --validation-cmd)
      validation_cmds+=("${2:-}")
      shift 2
      ;;
    --push)
      push_dev=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --allow-local-branch)
      allow_local_branch=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    task/*)
      if [[ -n "${legacy_single_branch}" && "$1" == "${legacy_single_branch}" ]]; then
        shift
      else
        die "positional task branch is only supported as the sole argument; prefer --repo PATH --task-branch BRANCH --task-id TASK-XXXX --push"
      fi
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "${repo}" ]] || die "--repo is required"
[[ -n "${task_branch}" ]] || die "--task-branch is required"
[[ "${task_branch}" != *","* && "${task_branch}" != *" "* ]] || die "batch branch lists are forbidden; merge one task branch at a time"
[[ "${task_branch}" != "dev" && "${task_branch}" != "main" ]] || die "refusing to merge protected branch '${task_branch}' as a task branch"

repo="$(cd -- "${repo}" && pwd -P)"
[[ -d "${repo}/.git" ]] || die "not a git repository: ${repo}"

git_in_repo() {
  git -C "${repo}" "$@"
}

infer_task_id_from_branch() {
  local branch="$1"
  local inferred=""

  inferred="$(git_in_repo diff --name-only origin/dev..."${branch}" 2>/dev/null \
    | sed -n 's#^docs/development/tasks/\(TASK-[A-Z0-9-]*\)\.md$#\1#p' \
    | head -1 || true)"
  if [[ -n "${inferred}" ]]; then
    echo "${inferred}"
    return 0
  fi

  inferred="$(git_in_repo log -1 --format=%s "${branch}" 2>/dev/null \
    | grep -Eo 'TASK-[A-Z0-9]+(-[A-Z0-9]+)*' \
    | head -1 || true)"
  if [[ -n "${inferred}" ]]; then
    echo "${inferred}"
    return 0
  fi

  return 1
}

if [[ -z "${task_id}" && -n "${legacy_single_branch}" ]]; then
  git_in_repo fetch origin dev >/dev/null 2>&1 || true
  git_in_repo fetch origin "${task_branch}" >/dev/null 2>&1 || true
  task_id="$(infer_task_id_from_branch "origin/${task_branch}" 2>/dev/null || infer_task_id_from_branch "${task_branch}" 2>/dev/null || true)"
  [[ -n "${task_id}" ]] || die "legacy one-argument form could not infer TASK-ID; rerun with --task-id TASK-XXXX"
  info "legacy invocation detected; inferred --repo ${repo} --task-branch ${task_branch} --task-id ${task_id} --push"
fi

[[ -n "${task_id}" ]] || die "--task-id is required"
[[ "${task_id}" =~ ^TASK-[A-Z0-9]+(-[A-Z0-9]+)*$ ]] || die "--task-id must look like TASK-XXXX"

repo_name="$(basename "${repo}")"
timestamp="$(date +%Y%m%d%H%M%S)"
safe_task_id="$(echo "${task_id}" | tr '[:upper:]' '[:lower:]')"
safe_branch="$(echo "${task_branch}" | tr '/:@ ' '----' | tr -cd 'A-Za-z0-9._-')"
rescue_branch="rescue/${repo_name}-dev-before-${safe_task_id}-${timestamp}"
integration_branch="integration/${safe_task_id}-${safe_branch}-${timestamp}"

ensure_no_operation_in_progress() {
  [[ ! -e "$(git_in_repo rev-parse --git-path MERGE_HEAD)" ]] || die "merge in progress in ${repo}"
  [[ ! -e "$(git_in_repo rev-parse --git-path CHERRY_PICK_HEAD)" ]] || die "cherry-pick in progress in ${repo}"
  [[ ! -d "$(git_in_repo rev-parse --git-path rebase-merge)" ]] || die "rebase in progress in ${repo}"
  [[ ! -d "$(git_in_repo rev-parse --git-path rebase-apply)" ]] || die "rebase/apply in progress in ${repo}"
}

ensure_clean_worktree() {
  local status
  status="$(git_in_repo status --porcelain)"
  [[ -z "${status}" ]] || {
    echo "${status}" >&2
    die "worktree is dirty; commit, stash, or clean intentionally before merge"
  }
}

default_validation_cmds() {
  case "${repo_name}" in
    livemask-docs)
      echo "bash scripts/check-docs.sh"
      ;;
    livemask-backend)
      echo "go test ./... -count=1"
      echo "go vet ./..."
      echo "go build ./..."
      ;;
    livemask-admin)
      echo "npx vitest run"
      echo "npx next build"
      ;;
    livemask-app)
      echo "flutter analyze"
      echo "flutter test"
      ;;
    livemask-nodeagent)
      echo "go test ./... -count=1"
      echo "go build ./cmd/nodeagent"
      ;;
    livemask-job-service)
      echo "go test ./... -count=1"
      echo "go vet ./..."
      echo "go build ./cmd/job-service"
      ;;
    livemask-ci-cd)
      echo "bash -n scripts/*.sh"
      echo "git diff --check"
      ;;
    livemask-website)
      echo "npm run build"
      ;;
    *)
      die "no default validation profile for ${repo_name}; pass --validation-cmd"
      ;;
  esac
}

run_validation() {
  local label="$1"
  shift
  local cmd

  info "validation on ${label}"
  for cmd in "$@"; do
    info "run: ${cmd}"
    (cd -- "${repo}" && bash -lc "${cmd}")
  done
}

merge_or_abort() {
  local source_ref="$1"
  local target_label="$2"

  info "merge ${source_ref} into ${target_label}"
  if ! git_in_repo merge --no-ff --no-edit "${source_ref}"; then
    echo "Merge conflict files:" >&2
    git_in_repo status --short >&2 || true
    git_in_repo merge --abort >/dev/null 2>&1 || true
    die "merge conflict while merging ${source_ref}; aborted merge and stopped"
  fi
}

if [[ "${#validation_cmds[@]}" -eq 0 ]]; then
  while IFS= read -r cmd; do
    validation_cmds+=("${cmd}")
  done < <(default_validation_cmds)
fi

ensure_no_operation_in_progress
ensure_clean_worktree

info "repo: ${repo}"
info "task: ${task_id}"
info "task branch: ${task_branch}"
info "fetch origin dev and task branch"
git_in_repo fetch origin dev
git_in_repo fetch origin "${task_branch}" || true

git_in_repo rev-parse --verify --quiet "origin/dev^{commit}" >/dev/null || die "origin/dev not found"

task_ref="${task_branch}"
if git_in_repo rev-parse --verify --quiet "origin/${task_branch}^{commit}" >/dev/null; then
  task_ref="origin/${task_branch}"
elif git_in_repo rev-parse --verify --quiet "${task_branch}^{commit}" >/dev/null; then
  if [[ "${allow_local_branch}" != "true" ]]; then
    die "task branch has no origin/${task_branch} backup; push it or pass --allow-local-branch explicitly"
  fi
else
  die "task branch not found locally or on origin: ${task_branch}"
fi

if git_in_repo merge-base --is-ancestor "${task_ref}" origin/dev; then
  info "${task_ref} is already merged into origin/dev"
  exit 0
fi

info "origin/dev: $(git_in_repo rev-parse --short origin/dev)"
info "${task_ref}: $(git_in_repo rev-parse --short "${task_ref}")"

if [[ "${dry_run}" == "true" ]]; then
  cat <<EOF
DRY-RUN REPORT
  Repo path (resolved): ${repo}
  Task branch:         ${task_branch}
  Task ref:            ${task_ref}
  Task ID:             ${task_id}
  Rescue branch:       ${rescue_branch}
  Integration branch:  ${integration_branch}
  Push to origin/dev:  ${push_dev}
Preflight checks PASS; --dry-run set, no merge performed.
EOF
  exit 0
fi

info "create rescue branch ${rescue_branch}"
git_in_repo branch "${rescue_branch}" origin/dev

info "create integration branch ${integration_branch} from origin/dev"
git_in_repo checkout -B "${integration_branch}" origin/dev
merge_or_abort "${task_ref}" "${integration_branch}"
run_validation "${integration_branch}" "${validation_cmds[@]}"

integration_commit="$(git_in_repo rev-parse --short HEAD)"
info "integration validation PASS at ${integration_commit}"

if [[ "${push_dev}" != "true" ]]; then
  cat <<EOF

Dev merge guard stopped before touching dev because --push was not provided.
To complete the task, rerun with --push after reviewing integration result.

Task Branch: ${task_ref} ($(git_in_repo rev-parse --short "${task_ref}"))
Integration Branch: ${integration_branch} (${integration_commit})
Rescue Branch: ${rescue_branch}
EOF
  exit 0
fi

info "checkout dev from origin/dev"
git_in_repo checkout -B dev origin/dev
merge_or_abort "${integration_branch}" "dev"
run_validation "dev" "${validation_cmds[@]}"

dev_commit="$(git_in_repo rev-parse --short HEAD)"
info "push dev to origin/dev"
git_in_repo push origin dev
remote_dev="$(git_in_repo ls-remote origin refs/heads/dev | awk '{print substr($1,1,7)}')"

cat <<EOF

Dev merge guard PASS.

TASK ID: ${task_id}
Repository: ${repo_name}
Task Branch: ${task_ref} ($(git_in_repo rev-parse --short "${task_ref}"))
Integration Branch: ${integration_branch} (${integration_commit})
Dev Merge Commit: ${dev_commit}
Remote dev Ref: ${remote_dev}
Rescue Branch: ${rescue_branch}
Validation on dev: PASS
EOF
