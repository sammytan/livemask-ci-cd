#!/usr/bin/env bash
# TASK-CICD-RUNNER-BACKLOG-001 — Lark notification with runtime-level evidence.
#
# Reads runtime status JSON (from dev-runtime-status.sh), blend with GitHub
# Actions context, and sends an enriched Lark interactive card.
#
# Usage:
#   RUNTIME_STATUS_JSON='{...}' bash .github/scripts/lark-runtime-notify.sh <result>
#
# Or:
#   bash .github/scripts/lark-runtime-notify.sh <result> [runtime-status-file]
#
# Required env:
#   WORKFLOW_RESULT  or  argument 1  — success / failure / cancelled
#   LARK_BOT_WEBHOOK                  — Lark bot webhook URL
#   GITHUB_TOKEN                      — GitHub API token (for error log download)
#
# Optional env:
#   RUNTIME_STATUS_JSON  — inline runtime status JSON
#   RUNTIME_ENV          — staging or dev (default: staging)
#   GITHUB_REPOSITORY    — repo (from Actions context)
#   GITHUB_WORKFLOW      — workflow name
#   GITHUB_RUN_ID        — run ID
#   GITHUB_RUN_NUMBER    — run number
#   GITHUB_REF_NAME      — ref name
#   GITHUB_ACTOR         — trigger actor
#   GITHUB_SHA           — commit SHA
#   GITHUB_EVENT_NAME    — trigger event name

set -euo pipefail

# ============================================================
# Parse args
# ============================================================
RESULT="${1:-${WORKFLOW_RESULT:-unknown}}"
STATUS_FILE="${2:-}"

if [[ -z "${LARK_BOT_WEBHOOK:-}" ]]; then
  echo "LARK_BOT_WEBHOOK not configured; skip Lark runtime notification."
  exit 0
fi

# Load runtime status JSON: from env var, file arg, or stdin
RUNTIME_JSON="${RUNTIME_STATUS_JSON:-}"
if [[ -z "${RUNTIME_JSON}" && -n "${STATUS_FILE}" && -f "${STATUS_FILE}" ]]; then
  RUNTIME_JSON=$(cat "${STATUS_FILE}")
fi

# If STAGING_RUNTIME_STATUS is set (from workflow output), use that
if [[ -z "${RUNTIME_JSON}" && -n "${STAGING_RUNTIME_STATUS:-}" ]]; then
  RUNTIME_JSON="${STAGING_RUNTIME_STATUS}"
fi

# Fallback: empty JSON
if [[ -z "${RUNTIME_JSON}" ]]; then
  RUNTIME_JSON='{"compose_up_detected":null,"all_containers_up":null,"container_summary":"no data","health_all_pass":null,"refs":{}}'
fi

# ============================================================
# Build and send Lark card via Python
# ============================================================
python3 - "$RESULT" "$RUNTIME_JSON" <<'PYTHON_SCRIPT'
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

result = sys.argv[1]
runtime_json_raw = sys.argv[2]

# Parse runtime status
try:
    rt = json.loads(runtime_json_raw)
except json.JSONDecodeError:
    rt = {}

# Environment variables from GitHub Actions
webhook = os.environ.get("LARK_BOT_WEBHOOK", "")
secret = os.environ.get("LARK_BOT_SECRET", "")
github_token = os.environ.get("GITHUB_TOKEN", "")
repo = os.environ.get("GITHUB_REPOSITORY", "unknown")
workflow = os.environ.get("GITHUB_WORKFLOW", "unknown")
run_id = os.environ.get("GITHUB_RUN_ID", "")
run_number = os.environ.get("GITHUB_RUN_NUMBER", "")
server_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
ref_name = os.environ.get("GITHUB_REF_NAME", "")
actor = os.environ.get("GITHUB_ACTOR", "")
sha = os.environ.get("GITHUB_SHA", "")
event_name = os.environ.get("GITHUB_EVENT_NAME", "unknown")
runtime_env = os.environ.get("RUNTIME_ENV", rt.get("environment", "staging"))

run_url = f"{server_url}/{repo}/actions/runs/{run_id}" if run_id else server_url

# -----------------------------------------------------------
# Determine trigger source
# -----------------------------------------------------------
trigger_source = event_name
if event_name == "push":
    trigger_source = "push to dev"
elif event_name == "workflow_dispatch":
    trigger_source = "workflow_dispatch"
elif event_name == "repository_dispatch":
    event_type = os.environ.get("GITHUB_EVENT_TYPE", "")
    trigger_source = f"repository_dispatch ({event_type})"

# -----------------------------------------------------------
# Translate runtime environment
# -----------------------------------------------------------
if runtime_env == "staging":
    env_label = "Ephemeral Staging Smoke"
elif runtime_env == "dev":
    env_label = "Persistent Dev Runtime"
else:
    env_label = runtime_env

# -----------------------------------------------------------
# Determine runtime state
# -----------------------------------------------------------
compose_up = rt.get("compose_up_detected", None)
all_containers_up = rt.get("all_containers_up", None)
container_summary = rt.get("container_summary", "no data")
health_pass = rt.get("health_all_pass", None)
hostname = rt.get("hostname", "")
uptime = rt.get("uptime", "")

# Collect container names
container_names = []
for c in rt.get("containers", []):
    if isinstance(c, dict):
        name = c.get("Name", c.get("name", ""))
        if name:
            container_names.append(name)

# Collect refs
refs = rt.get("refs", {})
failed_steps = []
error_snippets = []

# Build runtime detail lines
container_list_str = ", ".join(container_names[:10]) if container_names else "none"
refs_lines = []
for key in ["BACKEND_REF", "JOB_SERVICE_REF", "ADMIN_REF", "WEBSITE_REF", "APP_REF", "NODEAGENT_REF"]:
    val = refs.get(key, "")
    if val:
        refs_lines.append(f"• {key}={val}")

# -----------------------------------------------------------
# Failure analysis
# -----------------------------------------------------------
if result != "success":
    # Check for common failure patterns from error_excerpts
    error_excerpts_val = rt.get("error_excerpts", "")
    health_details = rt.get("health_details", "")

    if rt.get("compose_up_detected") is False:
        failed_steps.append("docker compose up")

    if rt.get("all_containers_up") is False:
        service = "container"
        fc = rt.get("failed_containers", "")
        if fc:
            from re import search as re_search
            m = re_search(r"livemask-(\w+)", fc)
            if m:
                service = m.group(1)
        failed_steps.append(f"container exited ({service})")

    if rt.get("health_all_pass") is False:
        failed_steps.append("health endpoint timeout")

    if "clone" in error_excerpts_val.lower() or "clone" in error_excerpts_val.lower():
        failed_steps.append("private repo clone failed")
    if "build" in error_excerpts_val.lower() and "failed" in error_excerpts_val.lower():
        failed_steps.append("Docker build failed")
    if "port" in error_excerpts_val.lower() and ("in use" in error_excerpts_val.lower() or "collision" in error_excerpts_val.lower()):
        failed_steps.append("port collision")

    if not failed_steps:
        failed_steps.append("workflow failure (check GitHub run logs)")

    # Extract error snippet (first 15 lines)
    if error_excerpts_val:
        lines = error_excerpts_val.strip().split("\n")[:15]
        error_snippets = lines
    elif health_details:
        lines = health_details.strip().split("\n")[:5]
        error_snippets = lines

# -----------------------------------------------------------
# Lark card template
# -----------------------------------------------------------
template_color = {
    "success": "green",
    "failure": "red",
    "cancelled": "yellow",
    "skipped": "grey",
}.get(result, "blue")

elements = []

# Section: Summary line
summary_line = (
    f"**Repository:** {repo}\n"
    f"**Workflow:** {workflow} #{run_number}\n"
    f"**Trigger:** {trigger_source}\n"
    f"**Environment:** {env_label}\n"
    f"**Ref:** {ref_name}\n"
    f"**Actor:** {actor}\n"
    f"**Commit:** {sha[:12]}\n"
    f"**Result:** {result}"
)

if hostname:
    summary_line += f"\n**Runner:** {hostname} ({uptime})"

elements.append({
    "tag": "div",
    "text": {"tag": "lark_md", "content": summary_line}
})

# Section: Git refs
if refs_lines:
    elements.append({"tag": "hr"})
    elements.append({
        "tag": "div",
        "text": {"tag": "lark_md", "content": "**Git Refs**\n" + "\n".join(refs_lines)}
    })

# Section: Runtime status
elements.append({"tag": "hr"})
runtime_status = (
    f"**Compose Up:** {compose_up if compose_up is not None else 'N/A'}\n"
    f"**Containers:** {container_summary}\n"
    f"**Service Names:** {container_list_str}\n"
    f"**Health Checks:** {'PASS' if health_pass else 'FAIL' if health_pass is False else 'N/A'}"
)
elements.append({
    "tag": "div",
    "text": {"tag": "lark_md", "content": runtime_status}
})

# Section: Health details
health_details = rt.get("health_details", "")
if health_details:
    elements.append({"tag": "hr"})
    elements.append({
        "tag": "div",
        "text": {"tag": "lark_md", "content": f"**Health Details**\n```text\n{health_details[:600]}\n```"}
    })

# Section: Error info (failure only)
if result != "success":
    elements.append({"tag": "hr"})
    error_content = "**Failed Phase:** " + ", ".join(failed_steps[:5]) if failed_steps else "**Failed Phase:** workflow error"
    elements.append({
        "tag": "div",
        "text": {"tag": "lark_md", "content": error_content}
    })

    if error_snippets:
        snippet_text = "\n".join(error_snippets)
        # Truncate to 1200 chars
        if len(snippet_text) > 1200:
            snippet_text = snippet_text[:1150] + "\n... (truncated)"
        elements.append({
            "tag": "div",
            "text": {"tag": "lark_md", "content": f"**Error Snippet**\n```text\n{snippet_text}\n```"}
        })

    # Try to fetch GitHub error logs (reuse logic from lark-notify.sh)
    error_excerpt = ""
    if result != "success" and github_token and run_id and "/" in repo:
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
            archive = None

        if archive:
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
                        matched = [idx for idx, line in enumerate(lines) if error_patterns.search(line)]
                        for idx in matched[:3]:
                            start = max(0, idx - 2)
                            end = min(len(lines), idx + 5)
                            block = "\n".join(lines[start:end])
                            snippets.append(f"[{name}]\n{block}")
                        if len(snippets) >= 3:
                            break
            except Exception:
                pass

            if snippets:
                excerpt_text = "\n\n".join(snippets)
                if len(excerpt_text) > 1200:
                    excerpt_text = excerpt_text[:1150] + "\n... (truncated)"
                error_excerpt = excerpt_text

    if error_excerpt and not error_snippets:
        elements.append({
            "tag": "div",
            "text": {"tag": "lark_md", "content": f"**Log Error Excerpt**\n```text\n{error_excerpt}\n```"}
        })

# Footer
elements.append({
    "tag": "note",
    "elements": [
        {"tag": "plain_text", "content": f"Runtime: {env_label} | Host: {hostname} | {time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())}"}
    ]
})

# Action button
elements.append({
    "tag": "action",
    "actions": [
        {
            "tag": "button",
            "text": {"tag": "plain_text", "content": "Open GitHub Run"},
            "url": run_url,
            "type": "primary",
        }
    ]
})

# Build card
card_title = f"{env_label} {result.upper()}"
payload = {
    "msg_type": "interactive",
    "card": {
        "config": {"wide_screen_mode": True},
        "header": {
            "template": template_color,
            "title": {"tag": "plain_text", "content": card_title},
        },
        "elements": elements,
    },
}

# Sign payload if secret is set
if secret:
    ts = str(int(time.time()))
    string_to_sign = f"{ts}\n{secret}"
    sign = base64.b64encode(
        hmac.new(string_to_sign.encode("utf-8"), b"", hashlib.sha256).digest()
    ).decode("utf-8")
    payload["timestamp"] = ts
    payload["sign"] = sign

# Send
request = urllib.request.Request(
    webhook,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(request, timeout=10) as response:
        body = response.read().decode("utf-8")
        print(f"Lark runtime notification sent: HTTP {response.status} {body}")
except (urllib.error.URLError, TimeoutError) as exc:
    print(f"Lark runtime notification failed but will not fail workflow: {exc}", file=sys.stderr)
PYTHON_SCRIPT
