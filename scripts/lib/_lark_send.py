#!/usr/bin/env python3
"""Send Lark card. Called from lark-notify.sh"""
import json, sys, urllib.request, time, pathlib

APP_ID = "cli_aa97755a49b8deef"
APP_SECRET = "rhPVWWmy78WMIr4XLZjswbVyH270iDc4"
USER_ID = "ou_8f472b84a9b3346116842dd0771a0275"
TOKEN_CACHE = pathlib.Path("/tmp/claude/lark-token.json")

def get_token():
    if TOKEN_CACHE.exists():
        try:
            d = json.loads(TOKEN_CACHE.read_text())
            if time.time() < d.get("expire", 0):
                return d["token"]
        except: pass
    r = urllib.request.urlopen(urllib.request.Request(
        'https://open.larksuite.com/open-apis/auth/v3/app_access_token/internal',
        data=json.dumps({"app_id": APP_ID, "app_secret": APP_SECRET}).encode(),
        headers={'Content-Type': 'application/json'}), timeout=10)
    d = json.loads(r.read())
    token = d.get('app_access_token', '')
    TOKEN_CACHE.write_text(json.dumps({"token": token, "expire": d.get("expire", 0) + time.time() - 300}))
    return token

def send_card(title, color, content):
    token = get_token()
    if not token:
        print(f"  [Lark] No token")
        return
    # Convert literal \n to actual newlines for proper formatting
    content = content.replace("\\n", "\n")
    card = {
        "receive_id": USER_ID,
        "msg_type": "interactive",
        "content": json.dumps({
            "config": {"wide_screen_mode": True},
            "header": {"title": {"tag": "plain_text", "content": title}, "template": color},
            "elements": [
                {"tag": "markdown", "content": content},
                {"tag": "hr"},
                {"tag": "note", "elements": [{"tag": "plain_text", "content": "LiveMask Engine · " + time.strftime('%H:%M', time.localtime())}]}
            ]
        })
    }
    r = urllib.request.Request(
        'https://open.larksuite.com/open-apis/im/v1/messages?receive_id_type=open_id',
        data=json.dumps(card).encode(),
        headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'})
    d = json.loads(urllib.request.urlopen(r, timeout=10).read())
    print(f"  [Lark] {'OK' if d.get('code')==0 else d.get('msg','?')}  {title}")

if __name__ == "__main__":
    if len(sys.argv) >= 4:
        send_card(sys.argv[1], sys.argv[2], sys.argv[3])
    else:
        print("Usage: _lark_send.py <title> <color> <content>")
