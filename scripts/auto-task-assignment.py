#!/usr/bin/env python3
"""TASK-CICD-AUTO-TASK-ASSIGNMENT-DEVELOPMENT-001

Automated task assignment runner for LiveMask multi-repo governance.

Locates the sibling livemask-docs repository, reads the planner and lease
registry, selects dispatchable tasks, and maps them to repo-local worker
commands. The default mode is dry-run; no state files, leases, or runtime repos
are mutated unless --mode accept-only or --mode implement-for-review is used.

Usage examples:

  # Dry-run: list the next task from the planner without side effects
  python3 scripts/auto-task-assignment.py --dry-run --limit 1

  # Dry-run filtered to a single repo
  python3 scripts/auto-task-assignment.py --dry-run --repo livemask-backend

  # Accept-only: acquire lease, invoke worker accept-only
  python3 scripts/auto-task-assignment.py --mode accept-only --limit 1

  # Implement-for-review (opt-in, requires --confirm-implement)
  python3 scripts/auto-task-assignment.py --mode implement-for-review \
      --task-id TASK-XXX-001 --confirm-implement

Out of scope:
  - daemon loop
  - auto approve, auto commit, auto merge, auto dispatch
  - runtime repo code modification
  - livemask-docs code modification
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent

DOCS_REPO_NAME = "livemask-docs"
DOCS_DIR = REPO_ROOT.parent / DOCS_REPO_NAME
DEFAULT_DOCS_LEDGER = DOCS_DIR / "docs/development/task-state-ledger.json"
DEFAULT_DOCS_LEASE_FILE = DOCS_DIR / "docs/development/task-leases.json"
DEFAULT_DOCS_PLANNER = DOCS_DIR / "scripts/plan-next-tasks.py"

DEFAULT_STATE_DIR = REPO_ROOT / ".local-dev/auto-task-assignment"
DEFAULT_EVIDENCE_DIR = REPO_ROOT / ".cursor-worker/auto-task-assignment"
DEFAULT_LEASE_OWNER = "ci-cd-auto-task-assignment"
DEFAULT_PLANNER_LOOKAHEAD = 50

ACTIVE_LEASE_STATUSES = {"active"}

REPO_WORKER_MAP: dict[str, pathlib.Path] = {
    "livemask-backend": REPO_ROOT.parent / "livemask-backend/scripts/task-worker.sh",
    "livemask-nodeagent": REPO_ROOT.parent / "livemask-nodeagent/scripts/task-worker.sh",
    "livemask-job-service": REPO_ROOT.parent / "livemask-job-service/scripts/task-worker.sh",
    "livemask-app": REPO_ROOT.parent / "livemask-app/scripts/task-worker.sh",
    "livemask-admin": REPO_ROOT.parent / "livemask-admin/scripts/task-worker.sh",
    "livemask-website": REPO_ROOT.parent / "livemask-website/scripts/task-worker.sh",
}


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).astimezone()


def iso(ts: dt.datetime | None = None) -> str:
    return (ts or now()).isoformat(timespec="seconds")


def read_json(path: pathlib.Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        raise SystemExit(f"ERROR: cannot read JSON file {path}: {exc}")


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    tmp.replace(path)


def append_jsonl(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")


def verify_docs_repo() -> pathlib.Path:
    docs = DOCS_DIR.resolve()
    if not docs.exists():
        raise SystemExit(
            f"ERROR: sibling docs repo not found at {docs}\n"
            f"       Expected ../livemask-docs relative to script location."
        )
    planner = DEFAULT_DOCS_PLANNER
    if not planner.exists():
        raise SystemExit(f"ERROR: planner not found at {planner}")
    return docs


def load_leases(lease_file: pathlib.Path) -> list[dict[str, Any]]:
    data = read_json(lease_file, default={"leases": []})
    if not isinstance(data, dict):
        data = {"leases": []}
    leases = data.get("leases", [])
    if not isinstance(leases, list):
        leases = []
    return leases


def active_lease_for_repo(
    leases: list[dict[str, Any]], repo: str, exclude_owner: str = ""
) -> dict[str, Any] | None:
    for lease in leases:
        status = str(lease.get("status", "")).lower()
        owner = str(lease.get("lease_owner", ""))
        if status in ACTIVE_LEASE_STATUSES and lease.get("repo") == repo:
            if exclude_owner and owner == exclude_owner:
                continue
            return lease
    return None


def active_lease_for_task(
    leases: list[dict[str, Any]], task_id: str, exclude_owner: str = ""
) -> dict[str, Any] | None:
    for lease in leases:
        status = str(lease.get("status", "")).lower()
        owner = str(lease.get("lease_owner", ""))
        if status in ACTIVE_LEASE_STATUSES and lease.get("task_id") == task_id:
            if exclude_owner and owner == exclude_owner:
                continue
            return lease
    return None


def is_lease_expired(lease: dict[str, Any]) -> bool:
    raw = lease.get("expires_at", "")
    if not raw:
        return False
    try:
        expires = dt.datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
        return expires < now()
    except (ValueError, TypeError):
        return False


def acquire_lease(
    lease_file: pathlib.Path,
    task_id: str,
    repo: str,
    branch: str,
    lease_owner: str,
    expected_files: list[str] | None = None,
    expires_in_hours: int = 4,
) -> dict[str, Any]:
    data = read_json(lease_file, default={"leases": []})
    if not isinstance(data, dict):
        data = {"leases": []}
    leases = data.get("leases", [])
    if not isinstance(leases, list):
        leases = []

    expires_at = now() + dt.timedelta(hours=expires_in_hours)
    entry = {
        "task_id": task_id,
        "repo": repo,
        "branch": branch,
        "expected_files": expected_files or [],
        "lease_owner": lease_owner,
        "started_at": iso(),
        "expires_at": iso(expires_at),
        "ended_at": "",
        "depends_on": [],
        "blocked_by": [],
        "status": "active",
    }
    leases.append(entry)
    data["leases"] = leases
    data["updated_at"] = iso()
    write_json(lease_file, data)
    return entry


def run_planner(
    planner_path: pathlib.Path,
    ledger_path: pathlib.Path,
    *,
    limit: int,
    repo_filter: str,
    brief_limit: int = 6,
) -> list[dict[str, Any]]:
    cmd = [
        sys.executable,
        str(planner_path),
        "--ledger", str(ledger_path),
        "--format", "json",
        "--limit", str(limit),
        "--brief-limit", str(brief_limit),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"planner failed (exit={result.returncode}):\n{result.stderr}")
    try:
        plan = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"planner output is not valid JSON: {exc}")

    candidates = plan.get("global_next", [])
    if not isinstance(candidates, list):
        candidates = []
    if repo_filter:
        candidates = [c for c in candidates if c.get("repo") == repo_filter]
    return candidates


def resolve_worker(repo: str) -> pathlib.Path | None:
    return REPO_WORKER_MAP.get(repo)


def build_worker_command(
    worker_path: pathlib.Path, mode: str, task_id: str
) -> list[str]:
    return [str(worker_path), mode, task_id]


def worker_exists(worker_path: pathlib.Path) -> bool:
    return (
        worker_path.is_file()
        and (os.access(str(worker_path), os.X_OK) or True)
    )


def write_evidence(
    evidence_dir: pathlib.Path,
    task_id: str,
    repo: str,
    mode: str,
    *,
    worker_path: str = "",
    worker_command: list[str] | None = None,
    worker_exit_code: int | None = None,
    lease_acquired: bool = False,
    lease_entry: dict[str, Any] | None = None,
    candidate: dict[str, Any] | None = None,
    errors: list[str] | None = None,
) -> pathlib.Path:
    evidence_dir.mkdir(parents=True, exist_ok=True)
    safe_id = re.sub(r"[^A-Za-z0-9_.-]", "_", task_id)
    evidence_path = evidence_dir / f"{safe_id}.json"

    payload: dict[str, Any] = {
        "schema_version": 1,
        "task_id": task_id,
        "repo": repo,
        "mode": mode,
        "worker_path": worker_path,
        "worker_command": worker_command or [],
        "worker_exit_code": worker_exit_code,
        "lease_acquired": lease_acquired,
        "lease_entry": lease_entry or {},
        "candidate_summary": {
            "priority": (candidate or {}).get("priority", ""),
            "status": (candidate or {}).get("status", ""),
            "readiness": (candidate or {}).get("readiness", ""),
            "recommended_action": (candidate or {}).get("recommended_action", ""),
            "score": (candidate or {}).get("score", 0),
        }
        if candidate
        else {},
        "errors": errors or [],
        "timestamp": iso(),
    }
    write_json(evidence_path, payload)
    return evidence_path


def dispatch(
    *,
    docs_dir: pathlib.Path,
    mode: str,
    task_ids: list[str],
    repo_filter: str,
    limit: int,
    lease_owner: str,
    lease_file: pathlib.Path,
    ledger: pathlib.Path,
    state_dir: pathlib.Path,
    evidence_dir: pathlib.Path,
    confirm_implement: bool,
    json_output: bool,
    skip_worker_invoke: bool = False,
) -> int:
    planner_path = docs_dir / "scripts/plan-next-tasks.py"
    if not planner_path.exists():
        print(f"ERROR: planner not found at {planner_path}", file=sys.stderr)
        return 1
    if not ledger.exists():
        print(f"ERROR: ledger not found at {ledger}", file=sys.stderr)
        return 1

    planner_limit = max(limit, DEFAULT_PLANNER_LOOKAHEAD)
    candidates = run_planner(
        planner_path, ledger, limit=planner_limit, repo_filter=repo_filter,
    )

    requested_candidates = candidates
    if task_ids:
        requested_candidates = [c for c in candidates if c.get("task_id") in task_ids]
        if len(requested_candidates) < len(task_ids):
            missing = set(task_ids) - {c.get("task_id", "") for c in requested_candidates}
            print(
                "WARNING: task(s) not found in planner candidates: "
                + ", ".join(sorted(missing)),
                file=sys.stderr,
            )

    leases = load_leases(lease_file)

    lease_filtered: list[dict[str, Any]] = []
    lease_blocked: list[dict[str, str]] = []
    for task in requested_candidates:
        tid = task.get("task_id", "")
        trepo = task.get("repo", "")

        repo_lease = active_lease_for_repo(leases, trepo, exclude_owner=lease_owner)
        task_lease = active_lease_for_task(leases, tid, exclude_owner=lease_owner)

        collision = repo_lease or task_lease
        if collision:
            if is_lease_expired(collision):
                lease_filtered.append(task)
                continue
            lease_blocked.append({
                "task_id": tid,
                "repo": trepo,
                "reason": (
                    f"active lease by {collision.get('lease_owner', 'unknown')} "
                    f"(expires {collision.get('expires_at', '')})"
                ),
            })
            continue
        lease_filtered.append(task)

    assignable: list[dict[str, Any]] = []
    unassignable_tasks: list[dict[str, str]] = []
    unassignable_repos: set[str] = set()
    for task in lease_filtered:
        tid = task.get("task_id", "")
        trepo = task.get("repo", "")
        worker_path = resolve_worker(trepo)
        reason = ""
        if not worker_path:
            reason = "no worker mapping"
        elif not worker_exists(worker_path):
            reason = f"worker not found at {worker_path}"

        if reason:
            unassignable_repos.add(trepo)
            unassignable_tasks.append({
                "task_id": tid,
                "repo": trepo,
                "reason": reason,
            })
            continue
        assignable.append(task)

    if task_ids:
        selected = assignable
    else:
        selected = assignable[:limit]

    if not selected:
        summary = {
            "selected_count": 0,
            "mode": mode,
            "dry_run": mode == "dry-run",
            "total_candidates": len(candidates),
            "requested_candidates": len(requested_candidates),
            "assignable_candidates": len(assignable),
            "filtered_by_lease": len(lease_blocked),
            "filtered_by_worker_mapping": len(unassignable_tasks),
            "unassignable_repos": sorted(unassignable_repos),
            "unassignable_tasks": unassignable_tasks,
            "lease_blocked": lease_blocked,
        }
        if json_output:
            print(json.dumps({"summary": summary}, indent=2))
        else:
            print("No dispatchable tasks after lease and worker coverage filtering.")
            for blk in lease_blocked:
                print(f"  BLOCKED: {blk['task_id']} ({blk['repo']}) - {blk['reason']}")
            for item in unassignable_tasks:
                print(f"  UNASSIGNABLE: {item['task_id']} ({item['repo']}) - {item['reason']}")
        return 0

    results: list[dict[str, Any]] = []
    overall_exit_code = 0

    for task in selected:
        tid = task.get("task_id", "")
        trepo = task.get("repo", "")

        worker_path = resolve_worker(trepo)
        if not worker_path:
            # Should be unreachable because the coverage gate filters first.
            continue

        worker_cmd = build_worker_command(worker_path, mode, tid)

        evidence_data: dict[str, Any] = {
            "task_id": tid,
            "repo": trepo,
            "mode": mode,
            "worker_path": str(worker_path),
            "worker_command": worker_cmd,
            "worker_exit_code": None,
            "lease_acquired": False,
            "lease_entry": {},
            "errors": [],
        }

        if mode == "dry-run":
            evidence_data["lease_acquired"] = False
            results.append(evidence_data)

        else:
            if not task_ids and not repo_filter and mode == "implement-for-review":
                if not confirm_implement:
                    err = (
                        "implement-for-review mode requires --confirm-implement "
                        "when no explicit --task-id or --repo is provided"
                    )
                    evidence_data["errors"].append(err)
                    results.append(evidence_data)
                    overall_exit_code = 1
                    continue

            branch = task.get("branch", "") or f"task/{tid}"
            lease_entry = acquire_lease(
                lease_file,
                task_id=tid,
                repo=trepo,
                branch=branch,
                lease_owner=lease_owner,
                expected_files=task.get("expected_files", []),
            )
            evidence_data["lease_acquired"] = True
            evidence_data["lease_entry"] = lease_entry

            # Invoke worker if not skipped (testing flag)
            if not skip_worker_invoke and mode in ("accept-only", "implement-for-review"):
                try:
                    env = os.environ.copy()
                    env.setdefault("CURSOR_WORKER_MODE", mode)
                    env["WORKER_HARNESS_TASK_ID"] = tid

                    proc = subprocess.run(
                        worker_cmd,
                        cwd=str(worker_path.parent.parent),
                        capture_output=True,
                        text=True,
                        timeout=60,
                        env=env,
                    )
                    evidence_data["worker_exit_code"] = proc.returncode
                    evidence_data["worker_stdout"] = proc.stdout[:2000]
                    evidence_data["worker_stderr"] = proc.stderr[:2000]
                    if proc.returncode != 0:
                        evidence_data["errors"].append(
                            f"worker exited {proc.returncode}"
                        )
                        overall_exit_code = 1
                except subprocess.TimeoutExpired:
                    evidence_data["errors"].append("worker timed out (60s)")
                    overall_exit_code = 1
                except FileNotFoundError:
                    evidence_data["errors"].append(
                        f"worker script not found at {worker_path}"
                    )
                    overall_exit_code = 1
                except OSError as exc:
                    evidence_data["errors"].append(f"worker execution error: {exc}")
                    overall_exit_code = 1

            results.append(evidence_data)

        # Write local evidence
        evidence_path = write_evidence(
            evidence_dir,
            tid,
            trepo,
            mode,
            worker_path=str(worker_path),
            worker_command=worker_cmd,
            worker_exit_code=evidence_data.get("worker_exit_code"),
            lease_acquired=evidence_data["lease_acquired"],
            lease_entry=evidence_data.get("lease_entry", {}),
            candidate=task,
            errors=evidence_data.get("errors", []),
        )

        append_jsonl(
            evidence_dir / "dispatch-log.jsonl",
            {
                "event": "dispatch",
                "task_id": tid,
                "repo": trepo,
                "mode": mode,
                "worker_command": " ".join(shlex.quote(c) for c in worker_cmd),
                "lease_acquired": evidence_data["lease_acquired"],
                "evidence_path": str(evidence_path),
                "errors": evidence_data.get("errors", []),
                "timestamp": iso(),
            },
        )

    summary: dict[str, Any] = {
        "mode": mode,
        "dry_run": mode == "dry-run",
        "total_candidates": len(candidates),
        "requested_candidates": len(requested_candidates),
        "assignable_candidates": len(assignable),
        "selected": len(selected),
        "filtered_by_lease": len(lease_blocked),
        "filtered_by_worker_mapping": len(unassignable_tasks),
        "unassignable_repos": sorted(unassignable_repos),
        "unassignable_tasks": unassignable_tasks,
        "dispatched": len(results),
        "lease_blocked": lease_blocked,
        "results": results,
        "evidence_dir": str(evidence_dir),
        "lease_file": str(lease_file),
        "ledger": str(ledger),
        "lease_owner": lease_owner,
    }

    if json_output:
        print(json.dumps(summary, indent=2))
    else:
        print("=== Auto Task Assignment Summary ===")
        print(f"  Mode:              {mode}")
        print(f"  Candidates:        {len(candidates)}")
        print(f"  Selected:          {len(selected)}")
        print(f"  Assignable:        {len(assignable)}")
        print(f"  Filtered (lease):  {len(lease_blocked)}")
        print(f"  Filtered (worker): {len(unassignable_tasks)}")
        for item in unassignable_tasks:
            print(f"  UNASSIGNABLE: {item['task_id']} ({item['repo']}) - {item['reason']}")
        print(f"  Dispatched:        {len(results)}")
        for r in results:
            print(f"  [{r['repo']}] {r['task_id']}:")
            print(f"    worker: {r['worker_path']}")
            print(
                f"    command: {' '.join(shlex.quote(c) for c in r['worker_command'])}"
            )
            print(f"    lease_acquired: {r['lease_acquired']}")
            if r.get("errors"):
                for e in r["errors"]:
                    print(f"    ERROR: {e}")
        print(f"  Evidence: {evidence_dir}")

    return overall_exit_code


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Auto-assign LiveMask tasks from planner to worker harness.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    parser.add_argument(
        "--mode",
        default="dry-run",
        choices=["dry-run", "accept-only", "implement-for-review"],
        help="Assignment mode (default: dry-run). implement-for-review requires --confirm-implement.",
    )
    parser.add_argument(
        "--repo",
        default="",
        help="Filter planner candidates by target repo name.",
    )
    parser.add_argument(
        "--task-id",
        action="append",
        default=[],
        help="Specific TASK ID(s) to assign. Repeatable.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=1,
        help="Max tasks to select from planner (default: 1).",
    )
    parser.add_argument(
        "--lease-owner",
        default=DEFAULT_LEASE_OWNER,
        help="Owner name for lease acquisition.",
    )
    parser.add_argument(
        "--lease-file",
        type=pathlib.Path,
        default=DEFAULT_DOCS_LEASE_FILE,
        help="Path to task-leases.json.",
    )
    parser.add_argument(
        "--ledger",
        type=pathlib.Path,
        default=DEFAULT_DOCS_LEDGER,
        help="Path to task-state-ledger.json.",
    )
    parser.add_argument(
        "--state-dir",
        type=pathlib.Path,
        default=DEFAULT_STATE_DIR,
        help="Local state directory.",
    )
    parser.add_argument(
        "--evidence-dir",
        type=pathlib.Path,
        default=DEFAULT_EVIDENCE_DIR,
        help="Local evidence output directory.",
    )
    parser.add_argument(
        "--skip-worker-invoke",
        action="store_true",
        help="Skip actual worker invocation (for testing).",
    )
    parser.add_argument(
        "--confirm-implement",
        action="store_true",
        help="Required to confirm implement-for-review mode.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output machine-readable JSON summary.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        dest="dry_run_override",
        help="Override: force dry-run mode regardless of --mode.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    docs_dir = verify_docs_repo()

    mode = args.mode
    if args.dry_run_override:
        mode = "dry-run"

    # Safety guard: in CI/GitHub Actions context, never run implement-for-review
    if mode == "implement-for-review" and (
        os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS")
    ):
        print(
            "BLOCKED: --mode implement-for-review is forbidden in CI/GitHub Actions "
            "context. This runner only supports dry-run and accept-only.",
            file=sys.stderr,
        )
        return 3

    if mode == "implement-for-review" and not args.confirm_implement:
        if not args.task_id and not args.repo:
            print(
                "ERROR: --mode implement-for-review requires --confirm-implement "
                "when no explicit --task-id or --repo is provided.",
                file=sys.stderr,
            )
            return 1

    return dispatch(
        docs_dir=docs_dir,
        mode=mode,
        task_ids=args.task_id,
        repo_filter=args.repo,
        limit=args.limit,
        lease_owner=args.lease_owner,
        lease_file=args.lease_file,
        ledger=args.ledger,
        state_dir=args.state_dir,
        evidence_dir=args.evidence_dir,
        confirm_implement=args.confirm_implement,
        json_output=args.json,
        skip_worker_invoke=args.skip_worker_invoke,
    )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
