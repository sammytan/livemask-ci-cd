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
        hmac.new(secret.encode("utf-8"), string_to_sign.encode("utf-8"), hashlib.sha256).digest()
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
