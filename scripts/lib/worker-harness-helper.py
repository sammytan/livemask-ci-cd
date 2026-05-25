#!/usr/bin/env python3
"""
TASK-CICD-CURSOR-SDK-WORKER-HARDENING-001

Helper script for the Cursor SDK Worker Harness bash library.

Provides JSON building functions that bash cannot easily do inline:
  - build_review_packet: produce a review packet JSON from env vars
  - check_approval: validate a Codex approval artifact (with full binding)
  - check_docs_ack_listener: read reported_task_ids from a listener state
  - capture_completion_evidence: produce completion evidence JSON from env vars
  - read_approved_at: read approved_at from an approval artifact

Usage:
  python3 worker-harness-helper.py <command> [args...]
"""

from __future__ import annotations

import json
import os
import sys


def cmd_build_review_packet() -> None:
    """Read env vars and produce a review packet JSON."""
    data = {
        "now_iso": os.environ.get("PKT_NOW_ISO", ""),
        "mode": os.environ.get("PKT_MODE", ""),
        "task_id": os.environ.get("PKT_TASK_ID", ""),
        "current_branch": os.environ.get("PKT_CURRENT_BRANCH", ""),
        "expected_branch": os.environ.get("PKT_EXPECTED_BRANCH", ""),
        "branch_match": os.environ.get("PKT_BRANCH_MATCH", "false"),
        "branch_note": os.environ.get("PKT_BRANCH_NOTE", ""),
        "diff_summary": os.environ.get("PKT_DIFF_SUMMARY", ""),
        "diff_captured_path": os.environ.get("PKT_DIFF_CAPTURED_PATH", ""),
        "diff_file_count": os.environ.get("PKT_DIFF_FILE_COUNT", "0"),
        "diff_insert": os.environ.get("PKT_DIFF_INSERT", "0"),
        "diff_delete": os.environ.get("PKT_DIFF_DELETE", "0"),
        "changed_files_json": os.environ.get("PKT_CHANGED_FILES_JSON", "[]"),
        "boundary_result": os.environ.get("PKT_BOUNDARY_RESULT", "pass"),
        "secret_result": os.environ.get("PKT_SECRET_RESULT", "pass"),
        "secret_count": os.environ.get("PKT_SECRET_COUNT", "0"),
        "validation_json": os.environ.get("PKT_VALIDATION_JSON", "[]"),
        "agent_summary": os.environ.get("PKT_AGENT_SUMMARY", ""),
        "risks": os.environ.get("PKT_RISKS", ""),
    }

    try:
        changed_files = json.loads(data["changed_files_json"])
    except (json.JSONDecodeError, TypeError):
        changed_files = []

    try:
        validation = json.loads(data["validation_json"])
    except (json.JSONDecodeError, TypeError):
        validation = []

    risks_list = [r.strip() for r in data["risks"].split("|") if r.strip()]

    packet = {
        "review_packet_version": 1,
        "generated_at": data["now_iso"],
        "mode": data["mode"],
        "task_id": data["task_id"],
        "branch": {
            "current": data["current_branch"],
            "expected": data["expected_branch"],
            "match": data["branch_match"] == "true",
            "note": data["branch_note"],
        },
        "diff": {
            "summary": data["diff_summary"],
            "captured_at": data["diff_captured_path"],
            "file_count": int(data["diff_file_count"] or 0),
            "insertions": int(data["diff_insert"] or 0),
            "deletions": int(data["diff_delete"] or 0),
        },
        "changed_files": changed_files,
        "boundary_check": {
            "result": data["boundary_result"],
            "docs_repo_edits_found": data["boundary_result"] == "violation",
        },
        "secret_scan": {
            "result": data["secret_result"],
            "suspicious_count": int(data["secret_count"] or 0),
        },
        "validation": validation,
        "sdk_agent_summary": data["agent_summary"],
        "risks_and_todos": risks_list,
        "codex_approval_required_for_next_stage": True,
        "committed": False,
        "merged": False,
        "report_dispatched": False,
    }

    write_output(packet)


def cmd_check_approval() -> None:
    """Validate a Codex approval artifact.
    Args: approval_file expected_task_id expected_approval_id current_branch current_head_commit repo_name review_packet_sha256 diff_sha256"""
    approval_file = sys.argv[2]
    expected_task_id = sys.argv[3]
    expected_approval_id = sys.argv[4]
    current_branch = sys.argv[5]
    current_head_commit = sys.argv[6]
    repo_name = sys.argv[7]
    current_review_packet_sha256 = sys.argv[8]
    current_diff_sha256 = sys.argv[9]

    try:
        with open(approval_file) as f:
            art = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"invalid_approval_file: {e}")
        sys.exit(1)

    errors: list[str] = []

    # All required fields must be present
    required_fields = [
        "task_id", "repo", "branch", "head_commit_before_submit",
        "review_packet_sha256", "diff_sha256", "approved_at",
        "reviewer", "approval_id",
    ]
    for field in required_fields:
        if not art.get(field):
            errors.append(f"missing field: {field}")

    # Task ID match
    if art.get("task_id") != expected_task_id:
        errors.append(
            f"task_id mismatch: artifact='{art.get('task_id')}', expected='{expected_task_id}'"
        )

    # Approval ID match
    if art.get("approval_id") != expected_approval_id:
        errors.append(
            f"approval_id mismatch: artifact='{art.get('approval_id')}', expected='{expected_approval_id}'"
        )

    # Reviewer must be Codex
    if art.get("reviewer") != "Codex":
        errors.append(f"reviewer must be 'Codex', got '{art.get('reviewer')}'")

    # Branch match
    if art.get("branch") != current_branch:
        errors.append(
            f"branch mismatch: artifact='{art.get('branch')}', current='{current_branch}'"
        )

    # Repo match
    if art.get("repo") != repo_name:
        errors.append(
            f"repo mismatch: artifact='{art.get('repo')}', current='{repo_name}'"
        )

    # Head commit match (ensures no new commits after approval)
    if art.get("head_commit_before_submit") != current_head_commit:
        errors.append(
            f"head_commit mismatch: artifact='{art.get('head_commit_before_submit')}', current='{current_head_commit}'"
        )

    # Review packet sha256 match (detects diff mutation after review)
    if current_review_packet_sha256:
        if art.get("review_packet_sha256") != current_review_packet_sha256:
            errors.append(
                f"review_packet_sha256 mismatch: artifact='{art.get('review_packet_sha256')}', computed='{current_review_packet_sha256}'"
            )
    else:
        errors.append("current review packet not found for sha256 check")

    # Diff sha256 match (detects diff mutation after review)
    if current_diff_sha256:
        if art.get("diff_sha256") != current_diff_sha256:
            errors.append(
                f"diff_sha256 mismatch: artifact='{art.get('diff_sha256')}', computed='{current_diff_sha256}'"
            )
    else:
        errors.append("current diff file not found for sha256 check")

    # Permission checks — approved-submit requires BOTH commit AND merge permissions
    if art.get("allow_commit") is not True:
        errors.append("artifact does not grant commit permission (allow_commit != true)")

    if art.get("allow_merge") is not True:
        errors.append("artifact does not grant merge permission (allow_merge != true)")

    if errors:
        print("; ".join(errors))
        sys.exit(1)

    print("approval_artifact_valid")


def cmd_read_approved_at() -> None:
    """Read approved_at from an approval artifact file."""
    approval_file = sys.argv[2]
    try:
        with open(approval_file) as f:
            art = json.load(f)
        print(art.get("approved_at", ""))
    except (json.JSONDecodeError, OSError):
        print("")


def cmd_check_docs_ack_listener() -> None:
    """Read reported_task_ids from a listener state file."""
    listener_file = sys.argv[2]
    try:
        with open(listener_file) as f:
            data = json.load(f)
        print(" ".join(data.get("reported_task_ids", [])))
    except (json.JSONDecodeError, OSError):
        print("")


def cmd_capture_completion_evidence() -> None:
    """Read env vars and produce completion evidence JSON."""
    evidence = {
        "evidence_version": 1,
        "generated_at": os.environ.get("WH_NOW_ISO", ""),
        "task_id": os.environ.get("WH_TASK_ID", ""),
        "mode": os.environ.get("WH_MODE", ""),
        "task_branch_commit": os.environ.get("WH_TASK_BRANCH_COMMIT", ""),
        "dev_merge_commit": os.environ.get("WH_DEV_MERGE_COMMIT", ""),
        "remote_dev_ref": os.environ.get("WH_REMOTE_DEV_REF", ""),
        "validation_result": os.environ.get("WH_VALIDATION_RESULT", ""),
        "review_packet_path": os.environ.get("WH_PACKET_PATH", ""),
        "completion_time": os.environ.get("WH_NOW_ISO", ""),
        "docs_receiver_ack": "pending",
        "codex_approval_id": os.environ.get("WH_APPROVAL_ID", ""),
    }
    write_output(evidence)


def write_output(obj: dict) -> None:
    """Write a JSON object to stdout. If HARNESS_OUTPUT_FILE is set, write to file instead."""
    out_file = os.environ.get("HARNESS_OUTPUT_FILE", "")
    if out_file:
        with open(out_file, "w") as f:
            json.dump(obj, f, indent=2, ensure_ascii=False)
    else:
        print(json.dumps(obj, indent=2, ensure_ascii=False))


CMDS = {
    "build-review-packet": cmd_build_review_packet,
    "check-approval": cmd_check_approval,
    "read-approved-at": cmd_read_approved_at,
    "check-docs-ack-listener": cmd_check_docs_ack_listener,
    "capture-completion-evidence": cmd_capture_completion_evidence,
}


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <command> [args...]", file=sys.stderr)
        print(f"Commands: {', '.join(sorted(CMDS.keys()))}", file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd not in CMDS:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        print(f"Commands: {', '.join(sorted(CMDS.keys()))}", file=sys.stderr)
        sys.exit(1)

    CMDS[cmd]()


if __name__ == "__main__":
    main()
