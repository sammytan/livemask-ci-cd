#!/usr/bin/env python3
"""Lightweight webhook server — Lark + GitHub events with token auth.
Run: WEBHOOK_TOKEN=xxx python3 webhook-server.py --port 10086"""
import json, pathlib, time, os, hmac, hashlib
from http.server import HTTPServer, BaseHTTPRequestHandler
import argparse

EVENT_DIR = pathlib.Path(os.path.expanduser("~/.claude/role-cache/webhook-events"))
EVENT_DIR.mkdir(parents=True, exist_ok=True)
DEFAULT_TOKEN = os.environ.get("WEBHOOK_TOKEN", "livemask-webhook-2026")

def verify_token(headers):
    auth = headers.get("Authorization", headers.get("X-Webhook-Token", ""))
    token = auth.replace("Bearer ", "").replace("token ", "").strip()
    return token == DEFAULT_TOKEN

class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_len = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_len).decode('utf-8')
        headers = dict(self.headers)

        # Token verification (skip for health)
        if "/health" not in self.path and not verify_token(headers):
            self.respond(403, {"status": "denied", "message": "Invalid token"})
            return

        event = {"path": self.path, "received_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}

        # ── Lark Bot ──────────────────────────────────────────────────
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
                self.respond(200, {"status": "ok"})
            except Exception as e:
                self.respond(400, {"status": "error", "message": str(e)})

        # ── GitHub Workflow ───────────────────────────────────────────
        elif "/github" in self.path:
            try:
                data = json.loads(body)
                event["type"] = "github_workflow"
                event["action"] = data.get("action", "")
                wr = data.get("workflow_run", {})
                event["workflow"] = wr.get("name", "")
                event["conclusion"] = wr.get("conclusion", "")
                event["repo"] = data.get("repository", {}).get("name", "")
                event["url"] = wr.get("html_url", "")
                inbox = EVENT_DIR / "github-events.jsonl"
                with open(inbox, "a") as f:
                    f.write(json.dumps(event, ensure_ascii=False) + "\n")
                print(f"[GITHUB] {event['repo']}: {event['workflow']} → {event['conclusion']}")
                # Auto-trigger: if CI failed, write alert
                if event["conclusion"] == "failure":
                    alert = EVENT_DIR / "alerts.jsonl"
                    with open(alert, "a") as f:
                        f.write(json.dumps({"type":"ci_failure","repo":event['repo'],"workflow":event['workflow'],"url":event['url'],"at":event['received_at']}, ensure_ascii=False) + "\n")
                    print(f"[GITHUB] ALERT: CI failure in {event['repo']}!")
                self.respond(200, {"status": "ok"})
            except Exception as e:
                self.respond(400, {"status": "error", "message": str(e)})

        else:
            self.respond(404, {"status": "unknown endpoint"})

    def do_GET(self):
        if "/health" in self.path:
            self.respond(200, {"status": "healthy", "events": len(list(EVENT_DIR.glob("*.jsonl")))})
        else:
            self.respond(200, {"status": "webhook server running", "endpoints": ["POST /lark", "POST /github", "GET /health"], "port": 10086, "auth": "Bearer token required"})

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
    print(f"  Token:   {DEFAULT_TOKEN[:4]}***")
    print(f"  Lark:    POST /lark   (Header: Authorization: Bearer {DEFAULT_TOKEN})")
    print(f"  GitHub:  POST /github (Header: X-Webhook-Token: {DEFAULT_TOKEN})")
    print(f"  Health:  GET  /health")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()
