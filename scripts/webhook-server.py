#!/usr/bin/env python3
<<<<<<< Updated upstream
"""Webhook server — Lark receive + GitHub events with token auth.
Lark: receive messages → store to inbox → daemon processes.
GitHub: receive CI completion events → store + alerts.

Run: WEBHOOK_TOKEN=xxx python3 webhook-server.py --port 10086"""
import json, pathlib, time, os
=======
"""Lightweight webhook server for Lark + GitHub events.
Run: python3 webhook-server.py --port 10086
Receives events, writes to local file for daemon consumption."""
import json, pathlib, time, sys, os
>>>>>>> Stashed changes
from http.server import HTTPServer, BaseHTTPRequestHandler
import argparse

EVENT_DIR = pathlib.Path(os.path.expanduser("~/.claude/role-cache/webhook-events"))
EVENT_DIR.mkdir(parents=True, exist_ok=True)
<<<<<<< Updated upstream
DEFAULT_TOKEN = os.environ.get("WEBHOOK_TOKEN", "livemask-webhook-2026")

def store_requirement(text, user):
    f = EVENT_DIR / f"req-{int(time.time())}.json"
    f.write_text(json.dumps({"type":"requirement","user":user,"text":text,"at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}, ensure_ascii=False))
    return f

def store_bug(text, user):
    f = EVENT_DIR / f"bug-{int(time.time())}.json"
    f.write_text(json.dumps({"type":"bug_report","user":user,"text":text,"at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}, ensure_ascii=False))
    return f

def store_improvement(text, user):
    f = EVENT_DIR / f"improve-{int(time.time())}.json"
    f.write_text(json.dumps({"type":"improvement","user":user,"text":text,"at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}, ensure_ascii=False))
    return f

def classify_message(text):
    """Classify a Lark message and return (type, description)."""
    t = text.strip()
    if t.startswith("需求:") or t.startswith("提交需求:"):
        return "requirement", t.split(":", 1)[1].strip() if ":" in t else t
    if t.startswith("Bug:") or t.startswith("bug:") or t.startswith("提交Bug:"):
        return "bug_report", t.split(":", 1)[1].strip() if ":" in t else t
    if t.startswith("改进:") or t.startswith("功能改进:"):
        return "improvement", t.split(":", 1)[1].strip() if ":" in t else t
    if t in ("状态", "status", "状态查询", "查询"):
        return "status_query", ""
    if t in ("诊断", "diagnose", "运行诊断"):
        return "diagnose_trigger", ""
    if t in ("帮助", "help"):
        return "help", ""
    return "message", t

def verify_token(headers):
    auth = headers.get("Authorization", headers.get("X-Webhook-Token", ""))
    return auth.replace("Bearer ", "").replace("token ", "").strip() == DEFAULT_TOKEN

class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode('utf-8')

        if not verify_token(dict(self.headers)):
            self.respond(403, {"status": "denied", "message": "Invalid token"})
            return

        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        # ── Lark receive ───────────────────────────────────────────────
        if "/lark" in self.path:
            try:
                data = json.loads(body)
                if "event" in data:
                    msg_content = data["event"]["message"].get("content", "{}")
                    try: text = json.loads(msg_content).get("text", "")
                    except: text = msg_content
                    user = data["event"].get("sender", {}).get("sender_id", {}).get("open_id", "unknown")
                else:
                    text = data.get("text", data.get("content", ""))
                    user = data.get("user_name", "unknown")

                msg_type, description = classify_message(text)

                # Store in inbox (JSONL for daemon)
                event = {"type":"lark_message","msg_type":msg_type,"message":text,"user":user,"received_at":now}
                with open(EVENT_DIR / "lark-inbox.jsonl", "a") as f:
                    f.write(json.dumps(event, ensure_ascii=False) + "\n")

                # Store typed artifacts
                if msg_type == "requirement":
                    store_requirement(description, user)
                elif msg_type == "bug_report":
                    store_bug(description, user)
                elif msg_type == "improvement":
                    store_improvement(description, user)

                tag = {"requirement":"📋","bug_report":"🐛","improvement":"💡","status_query":"📊","diagnose_trigger":"🔧","help":"❓"}.get(msg_type,"💬")
                print(f"[LARK] {tag} {user}: {text[:80]} → {msg_type}")
                self.respond(200, {"status": "ok", "type": msg_type})

            except Exception as e:
                self.respond(400, {"status": "error", "message": str(e)})

        # ── GitHub CI ──────────────────────────────────────────────────
        elif "/github" in self.path:
            try:
                data = json.loads(body)
                wr = data.get("workflow_run", {})
                event = {
                    "type": "github_workflow",
                    "action": data.get("action", ""),
                    "workflow": wr.get("name", ""),
                    "conclusion": wr.get("conclusion", ""),
                    "repo": data.get("repository", {}).get("name", ""),
                    "url": wr.get("html_url", ""),
                    "received_at": now
                }
                with open(EVENT_DIR / "github-events.jsonl", "a") as f:
                    f.write(json.dumps(event, ensure_ascii=False) + "\n")

                tag = "✅" if event["conclusion"]=="success" else "❌" if event["conclusion"]=="failure" else "⏳"
                print(f"[GITHUB] {tag} {event['repo']}: {event['workflow']} → {event['conclusion']}")

                if event["conclusion"] == "failure":
                    with open(EVENT_DIR / "alerts.jsonl", "a") as f:
                        f.write(json.dumps({"type":"ci_failure","repo":event['repo'],"workflow":event['workflow'],"url":event['url'],"at":now}, ensure_ascii=False) + "\n")

                self.respond(200, {"status": "ok"})
            except Exception as e:
                self.respond(400, {"status": "error", "message": str(e)})
=======

class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_len = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_len).decode('utf-8')

        event = {"path": self.path, "received_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "headers": dict(self.headers)}

        if "/lark" in self.path:
            try:
                data = json.loads(body)
                event["type"] = "lark_message"
                event["message"] = data.get("text", data.get("content", ""))
                event["user"] = data.get("user_name", data.get("sender", {}).get("name", "unknown"))
                inbox = EVENT_DIR / "lark-inbox.jsonl"
                with open(inbox, "a") as f:
                    f.write(json.dumps(event, ensure_ascii=False) + "\n")
                print(f"[LARK] {event['user']}: {event['message'][:80]}")
                self.respond(200, {"status": "ok", "message": "Lark message received"})
            except Exception as e:
                self.respond(400, {"status": "error", "message": str(e)})

        elif "/github" in self.path:
            try:
                data = json.loads(body)
                event["type"] = "github_workflow"
                event["action"] = data.get("action", "")
                event["workflow"] = data.get("workflow_run", {}).get("name", "")
                event["conclusion"] = data.get("workflow_run", {}).get("conclusion", "")
                event["repo"] = data.get("repository", {}).get("name", "")
                event["url"] = data.get("workflow_run", {}).get("html_url", "")
                inbox = EVENT_DIR / "github-events.jsonl"
                with open(inbox, "a") as f:
                    f.write(json.dumps(event, ensure_ascii=False) + "\n")
                print(f"[GITHUB] {event['repo']}: {event['workflow']} → {event['conclusion']}")
                self.respond(200, {"status": "ok"})
            except Exception as e:
                self.respond(400, {"status": "error", "message": str(e)})

        elif "/health" in self.path:
            self.respond(200, {"status": "healthy", "events": len(list(EVENT_DIR.glob("*.jsonl")))})

>>>>>>> Stashed changes
        else:
            self.respond(404, {"status": "unknown endpoint"})

    def do_GET(self):
        if "/health" in self.path:
<<<<<<< Updated upstream
            counts = {f.name: sum(1 for _ in open(f)) for f in EVENT_DIR.glob("*.jsonl") if f.stat().st_size>0}
            self.respond(200, {"status": "healthy", "events": counts})
        else:
            self.respond(200, {"status": "webhook v3 (receive-only)", "endpoints": ["POST /lark", "POST /github", "GET /health"], "port": 10086})

    def respond(self, code, data):
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

    def log_message(self, format, *args): pass


if __name__ == "__main__":
    p = argparse.ArgumentParser(); p.add_argument("--port", type=int, default=10086); p.add_argument("--host", default="0.0.0.0")
    args = p.parse_args()
    server = HTTPServer((args.host, args.port), WebhookHandler)
    print(f"Webhook v3 (receive-only): http://{args.host}:{args.port}")
    print(f"  Token: {DEFAULT_TOKEN[:4]}***")
    print(f"  POST /lark   — receive Lark messages → store to inbox")
    print(f"  POST /github — receive CI events → store + alerts")
    print(f"  GET  /health — status")
    try: server.serve_forever()
    except KeyboardInterrupt: print("\nDone"); server.shutdown()
=======
            self.respond(200, {"status": "healthy"})
        else:
            self.respond(200, {"status": "webhook server running", "endpoints": ["/lark", "/github", "/health"], "port": 10086})

    def respond(self, code, data):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=10086)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()
    server = HTTPServer((args.host, args.port), WebhookHandler)
    print(f"Webhook server: http://{args.host}:{args.port}")
    print(f"  Lark endpoint:    POST /lark")
    print(f"  GitHub endpoint:  POST /github")
    print(f"  Health:           GET  /health")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()
>>>>>>> Stashed changes
