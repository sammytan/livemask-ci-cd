#!/usr/bin/env bash
set -euo pipefail

RESULT="${1:-${WORKFLOW_RESULT:-unknown}}"

if [[ -z "${LARK_BOT_WEBHOOK:-}" ]]; then
  echo "LARK_BOT_WEBHOOK is not configured; skip Lark notification."
  exit 0
fi

python3 - "$RESULT" <<'PY'
import base64
import hashlib
import hmac
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile

result = sys.argv[1] if len(sys.argv) > 1 else os.getenv("WORKFLOW_RESULT", "unknown")
webhook = os.environ["LARK_BOT_WEBHOOK"]
secret = os.getenv("LARK_BOT_SECRET", "")
github_token = os.getenv("GITHUB_TOKEN", "")
repo = os.getenv("GITHUB_REPOSITORY", "unknown")
workflow = os.getenv("GITHUB_WORKFLOW", "unknown")
run_id = os.getenv("GITHUB_RUN_ID", "")
run_number = os.getenv("GITHUB_RUN_NUMBER", "")
server_url = os.getenv("GITHUB_SERVER_URL", "https://github.com")
ref_name = os.getenv("GITHUB_REF_NAME", "")
actor = os.getenv("GITHUB_ACTOR", "")
sha = os.getenv("GITHUB_SHA", "")
report_kind = os.getenv("REPORT_KIND", "ci-cd")
report_title = os.getenv("REPORT_TITLE", "")
report_summary = os.getenv("REPORT_SUMMARY", "")
report_tasks = os.getenv("REPORT_TASKS", "")
report_risks = os.getenv("REPORT_RISKS", "")
report_next_steps = os.getenv("REPORT_NEXT_STEPS", "")
run_url = f"{server_url}/{repo}/actions/runs/{run_id}" if run_id else server_url

def truncate(text, limit=2600):
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[: limit - 80].rstrip() + "\n... truncated, open GitHub run for full logs."

def github_api(path, timeout=12):
    if not github_token:
        return None
    request = urllib.request.Request(
        f"https://api.github.com{path}",
        headers={
            "Authorization": f"Bearer {github_token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "livemask-lark-notifier",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception:
        return None

def load_event_payload():
    event_path = os.getenv("GITHUB_EVENT_PATH", "")
    if not event_path or not os.path.exists(event_path):
        return {}
    try:
        with open(event_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

def extract_task_ids(*texts):
    found = []
    pattern = re.compile(r"\bTASK-[A-Z0-9]+(?:-[A-Z0-9]+)*\b")
    for text in texts:
        for task_id in pattern.findall(text or ""):
            if task_id not in found:
                found.append(task_id)
    return found

def summarize_commit():
    event = load_event_payload()
    commit = None
    compare_url = ""
    changed_files = []

    if "/" in repo and sha:
        commit = github_api(f"/repos/{repo}/commits/{sha}") or None

    head_commit = event.get("head_commit") or {}
    commit_message = (
        (commit or {}).get("commit", {}).get("message")
        or head_commit.get("message")
        or ""
    )
    commit_title = commit_message.splitlines()[0] if commit_message else "(no commit title)"
    branch_hint = event.get("ref", "") or ref_name
    tasks = extract_task_ids(commit_message, branch_hint, workflow)

    if commit and isinstance(commit.get("files"), list):
        changed_files = [f.get("filename", "") for f in commit["files"] if f.get("filename")]
    else:
        changed_files = [
            f.get("filename", "")
            for f in (head_commit.get("added", []) + head_commit.get("modified", []) + head_commit.get("removed", []))
            if isinstance(f, str)
        ]

    compare_url = event.get("compare", "")

    top_dirs = []
    for filename in changed_files:
        top = filename.split("/", 1)[0]
        if top and top not in top_dirs:
            top_dirs.append(top)

    files_preview = changed_files[:8]
    if len(changed_files) > 8:
        files_preview.append(f"... +{len(changed_files) - 8} more")

    return {
        "title": commit_title,
        "tasks": tasks,
        "changed_files": changed_files,
        "top_dirs": top_dirs,
        "files_preview": files_preview,
        "compare_url": compare_url,
    }

def summarize_jobs():
    if not run_id or "/" not in repo:
        return ""
    data = github_api(f"/repos/{repo}/actions/runs/{run_id}/jobs?per_page=50")
    if not data:
        return ""
    rows = []
    for job in data.get("jobs", []):
        name = job.get("name", "unknown")
        conclusion = job.get("conclusion") or job.get("status") or "unknown"
        if name == "notify-lark":
            continue
        marker = {
            "success": "PASS",
            "failure": "FAIL",
            "cancelled": "CANCELLED",
            "skipped": "SKIPPED",
        }.get(conclusion, conclusion.upper())
        rows.append(f"• {name}: {marker}")
    return "\n".join(rows[:12])

change = summarize_commit()
jobs_summary = summarize_jobs()

if not report_summary:
    modules = ", ".join(change["top_dirs"][:8]) if change["top_dirs"] else "no file summary available"
    report_summary = (
        f"Change: {change['title']}\n"
        f"Affected paths: {modules}\n"
        f"Changed files: {len(change['changed_files'])}"
    )

if not report_tasks and change["tasks"]:
    report_tasks = "\n".join(f"• {task_id}" for task_id in change["tasks"])

if not report_next_steps:
    if report_kind == "ci-cd":
        report_next_steps = (
            "Dev runtime: not checked by this repo CI.\n"
            "Runtime status must come from livemask-ci-cd staging smoke or persistent dev-runtime deploy."
        )

def fetch_error_excerpt():
    if result == "success" or not github_token or not run_id or "/" not in repo:
        return ""

    api = f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/logs"
    request = urllib.request.Request(
        api,
        headers={
            "Authorization": f"Bearer {github_token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "livemask-lark-notifier",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            archive = response.read()
    except Exception as exc:
        return f"Log download failed: {exc}"

    error_patterns = re.compile(
        r"(error|failed|failure|exception|traceback|exit code|no such file|cannot|denied)",
        re.IGNORECASE,
    )
    snippets = []

    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as zf:
            for name in zf.namelist():
                if not name.endswith(".txt"):
                    continue
                content = zf.read(name).decode("utf-8", errors="replace")
                lines = content.splitlines()
                matched_indexes = [idx for idx, line in enumerate(lines) if error_patterns.search(line)]
                for idx in matched_indexes[:3]:
                    start = max(0, idx - 2)
                    end = min(len(lines), idx + 5)
                    block = "\n".join(lines[start:end])
                    snippets.append(f"[{name}]\n{block}")
                if len(snippets) >= 5:
                    break
    except Exception as exc:
        return f"Log parse failed: {exc}"

    if not snippets:
        return "No obvious error lines were found. Open GitHub run for full logs."

    return truncate("\n\n".join(snippets))

template = {
    "success": "green",
    "failure": "red",
    "cancelled": "yellow",
    "skipped": "grey",
}.get(result, "blue")

title = report_title or f"LiveMask CI/CD {result.upper()}"
subtitle = (
    f"**Repository:** {repo}\n"
    f"**Workflow:** {workflow} #{run_number}\n"
    f"**Ref:** {ref_name}\n"
    f"**Actor:** {actor}\n"
    f"**Commit:** {sha[:12]}\n"
    f"**Result:** {result}"
)

elements = [
    {
        "tag": "div",
        "text": {
            "tag": "lark_md",
            "content": subtitle,
        },
    }
]

if report_summary:
    elements.append({"tag": "hr"})
    elements.append(
        {
            "tag": "div",
            "text": {"tag": "lark_md", "content": f"**Summary**\n{truncate(report_summary, 1800)}"},
        }
    )

if report_tasks:
    elements.append({"tag": "hr"})
    elements.append(
        {
            "tag": "div",
            "text": {"tag": "lark_md", "content": f"**Tasks / Progress**\n{truncate(report_tasks, 1800)}"},
        }
    )

if change["files_preview"]:
    elements.append({"tag": "hr"})
    files_text = "\n".join(f"• {name}" for name in change["files_preview"])
    elements.append(
        {
            "tag": "div",
            "text": {"tag": "lark_md", "content": f"**Changed Files**\n{truncate(files_text, 1600)}"},
        }
    )

if jobs_summary:
    elements.append({"tag": "hr"})
    elements.append(
        {
            "tag": "div",
            "text": {"tag": "lark_md", "content": f"**Validation Jobs**\n{truncate(jobs_summary, 1600)}"},
        }
    )

if report_risks:
    elements.append({"tag": "hr"})
    elements.append(
        {
            "tag": "div",
            "text": {"tag": "lark_md", "content": f"**Risks / Blockers**\n{truncate(report_risks, 1600)}"},
        }
    )

if report_next_steps:
    elements.append({"tag": "hr"})
    elements.append(
        {
            "tag": "div",
            "text": {"tag": "lark_md", "content": f"**Next Steps**\n{truncate(report_next_steps, 1600)}"},
        }
    )

error_excerpt = fetch_error_excerpt()
if error_excerpt:
    elements.append({"tag": "hr"})
    elements.append(
        {
            "tag": "div",
            "text": {"tag": "lark_md", "content": f"**Error Log Summary**\n```text\n{error_excerpt}\n```"},
        }
    )

elements.append(
    {
        "tag": "note",
        "elements": [
            {
                "tag": "plain_text",
                "content": f"Report kind: {report_kind} | Generated by GitHub Actions",
            }
        ],
    }
)
elements.append(
    {
        "tag": "action",
        "actions": [
            {
                "tag": "button",
                "text": {"tag": "plain_text", "content": "Open GitHub Run"},
                "url": run_url,
                "type": "primary",
            }
        ],
    }
)

payload = {
    "msg_type": "interactive",
    "card": {
        "config": {"wide_screen_mode": True},
        "header": {
            "template": template,
            "title": {
                "tag": "plain_text",
                "content": title,
            },
        },
        "elements": elements,
    },
}

if secret:
    timestamp = str(int(time.time()))
    string_to_sign = f"{timestamp}\n{secret}"
    sign = base64.b64encode(
        hmac.new(string_to_sign.encode("utf-8"), b"", hashlib.sha256).digest()
    ).decode("utf-8")
    payload["timestamp"] = timestamp
    payload["sign"] = sign

request = urllib.request.Request(
    webhook,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
)

try:
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read().decode("utf-8")
        print(f"Lark notification sent: HTTP {response.status} {body}")
except (urllib.error.URLError, TimeoutError) as exc:
    print(f"Lark notification failed but will not fail workflow: {exc}", file=sys.stderr)
PY
