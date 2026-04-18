#!/usr/bin/env python3
"""
Localhost daemon that focuses an iTerm2 session by its unique id.

Invoked when a user clicks the Feishu notification link; runs AppleScript
to bring the matching iTerm2 tab to the foreground on the user's Mac.
"""
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOST = "127.0.0.1"
PORT = 47823
UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
ALLOWED_HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}", "127.0.0.1", "localhost"}

ASCRIPT = r'''
on run argv
  set targetId to item 1 of argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if unique id of s is targetId then
            select w
            select t
            select s
            return "ok"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "not_found"
end run
'''


def focus_session(uuid: str) -> str:
    # Launch Services respects cross-process activation from a launchd daemon;
    # AppleScript's `activate` does not in macOS Sonoma+.
    subprocess.run(["/usr/bin/open", "-a", "iTerm"], timeout=5)
    result = subprocess.run(
        ["/usr/bin/osascript", "-e", ASCRIPT, uuid],
        capture_output=True, text=True, timeout=5,
    )
    return (result.stdout or result.stderr).strip()


def reply(handler: BaseHTTPRequestHandler, status: int, body: str):
    handler.send_response(status)
    handler.send_header("Content-Type", "text/html; charset=utf-8")
    handler.send_header("Content-Length", str(len(body.encode("utf-8"))))
    handler.end_headers()
    handler.wfile.write(body.encode("utf-8"))


PAGE = """<!doctype html><meta charset="utf-8">
<title>{title}</title>
<style>body{{font:16px/1.5 -apple-system,sans-serif;text-align:center;padding:4em;color:#333}}</style>
<h2>{title}</h2><p>{msg}</p>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        host = self.headers.get("Host", "")
        if host not in ALLOWED_HOSTS:
            return reply(self, 403, PAGE.format(title="403", msg="bad host"))

        url = urlparse(self.path)
        if url.path != "/focus":
            return reply(self, 404, PAGE.format(title="404", msg="no such endpoint"))

        params = parse_qs(url.query)
        uuid = (params.get("id") or [""])[0]
        if not UUID_RE.match(uuid):
            return reply(self, 400, PAGE.format(title="400", msg="bad id"))

        try:
            result = focus_session(uuid)
        except Exception as e:
            return reply(self, 500, PAGE.format(title="500", msg=f"osascript failed: {e}"))

        if result == "ok":
            return reply(self, 200, PAGE.format(title="✅ 已切回", msg="iTerm2 那个会话应该在最前面了"))
        return reply(self, 404, PAGE.format(title="会话已关闭", msg=f"找不到 session {uuid[:8]}…，窗口可能关了"))

    def do_POST(self):
        reply(self, 405, PAGE.format(title="405", msg="GET only"))

    def log_message(self, fmt, *args):
        print(f"[daemon] {self.address_string()} - {fmt % args}", flush=True)


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[daemon] listening on http://{HOST}:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
