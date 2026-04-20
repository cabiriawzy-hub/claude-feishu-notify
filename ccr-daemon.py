#!/usr/bin/env python3
"""
Claude Code Remote (ccr) daemon — v3.

Bridges Claude Code hooks to Feishu interactive cards so the user can
approve/deny/pick from their phone when they're not at the computer.

Flow:
  PreToolUse hook --POST /approve--> daemon
    at_computer? yes  -> {"decision":"local"}              (hook exit 0)
                 no   -> send scenario card + wait tap
                         -> approve|deny|ask_pick|timeout
  Notification hook --POST /notify--> daemon
    at_computer? yes  -> skip (phone silent, user is here)
                 no   -> send info card with iTerm-focus button

One daemon per user, 127.0.0.1:19837 (loopback only).
"""
import json
import os
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional

HOST = "127.0.0.1"
PORT = 19837
OPEN_ID = "__OPEN_ID__"
LOG_PATH = "/tmp/ccr-daemon.log"

DEADLINE_SECS = 540
WAIT_SECS = 570

TERM_APPS = {"iTerm2", "Terminal", "Ghostty", "Alacritty", "kitty", "WezTerm"}

_start_time = time.time()
_subscribe_alive = False


def log(msg: str):
    print(f"[{time.strftime('%F %T')}] {msg}", flush=True)


def at_computer() -> bool:
    """True iff frontmost app is a terminal in TERM_APPS.
    Uses lsappinfo (native, ~10ms) instead of osascript which can hang 3-10s
    on System Events cold-start. Lock screen → frontmost=loginwindow;
    screensaver → ScreenSaverEngine; neither is in TERM_APPS."""
    try:
        asn = subprocess.run(
            ["/usr/bin/lsappinfo", "front"],
            capture_output=True, text=True, timeout=2,
        )
        asn_id = asn.stdout.strip()
        if asn.returncode != 0 or not asn_id:
            log(f"at_computer: lsappinfo front rc={asn.returncode}")
            return False
        r = subprocess.run(
            ["/usr/bin/lsappinfo", "info", "-only", "name", asn_id],
            capture_output=True, text=True, timeout=2,
        )
        if r.returncode != 0:
            log(f"at_computer: lsappinfo info rc={r.returncode}")
            return False
        # Format: "LSDisplayName"="iTerm2"
        out = r.stdout.strip()
        name = out.split("=", 1)[1].strip().strip('"') if "=" in out else ""
        return name in TERM_APPS
    except Exception as e:
        log(f"at_computer: lsappinfo failed: {e}")
        return False


@dataclass
class Pending:
    event: threading.Event = field(default_factory=threading.Event)
    decision: Optional[str] = None
    pick_index: Optional[int] = None
    pick_label: Optional[str] = None
    scenario: str = "bash"
    summary: str = ""
    deadline: float = 0.0
    card_message_id: Optional[str] = None


pending: dict[str, Pending] = {}
pending_lock = threading.Lock()

# Remember the original notify card dict keyed by message_id, so when the user
# taps "🙅 我先忙" we can patch it into a grey/dismissed variant that PRESERVES
# the original text ("Claude 想跑 git push 过来看一眼～") instead of replacing
# the whole card with a short receipt.
notify_cards: dict[str, dict] = {}
notify_cards_lock = threading.Lock()

# Follow-up timers for silenced permission notifications. When /notify arrives
# with silence_if_at_computer=true AND at_computer=true, we don't want to ping
# the phone immediately (user sees local menu) — but if they ignore the menu
# for 60s+, we WANT a ping. Claude Code doesn't fire a second Notification on
# its own, so daemon schedules one. Cancelled by /cancel-pending which is
# called from PostToolUse + UserPromptSubmit hooks.
FOLLOWUP_DELAY = 60.0
followup_timers: dict[str, threading.Timer] = {}
followup_lock = threading.Lock()


def _collapse_path(p: str) -> str:
    home = os.path.expanduser("~")
    return "~" + p[len(home):] if p.startswith(home) else p


def _truncate(s: str, n: int) -> str:
    return s if len(s) <= n else s[:n] + "…"


def _focus_button(url: Optional[str]) -> Optional[dict]:
    if not url:
        return None
    return {
        "tag": "button",
        "text": {"tag": "plain_text", "content": "🖥️ 切回 iTerm"},
        "type": "default",
        "url": url,
    }


def build_bash_card(rid: str, cmd: str, humanized: str, cwd: str,
                    focus_url: Optional[str]) -> dict:
    cmd_display = _truncate(cmd, 200)
    content_md = f"**命令**: `{cmd_display}`\n**目录**: {_collapse_path(cwd)}"
    if humanized:
        content_md += f"\n**解读**: {humanized}"
    actions = [
        {"tag": "button", "text": {"tag": "plain_text", "content": "✅ 批准"},
         "type": "primary",
         "value": {"action": "approve", "request_id": rid}},
        {"tag": "button", "text": {"tag": "plain_text", "content": "❌ 拒绝"},
         "type": "danger",
         "value": {"action": "deny", "request_id": rid}},
    ]
    fb = _focus_button(focus_url)
    if fb:
        actions.append(fb)
    return {
        "config": {"wide_screen_mode": True},
        "header": {"template": "red",
                   "title": {"tag": "plain_text",
                             "content": "⚠️ Claude 想跑高风险命令"}},
        "elements": [
            {"tag": "div", "text": {"tag": "lark_md", "content": content_md}},
            {"tag": "action", "actions": actions},
        ],
    }


def build_write_edit_card(rid: str, tool: str, file_path: str, preview: str,
                          cwd: str, focus_url: Optional[str]) -> dict:
    rel = file_path
    if cwd and file_path.startswith(cwd):
        rel = file_path[len(cwd):].lstrip("/")
    title = "📝 Claude 想写文件" if tool == "Write" else "📝 Claude 想改文件"
    content_md = (f"**工具**: {tool}\n"
                  f"**文件**: `{_truncate(rel, 120)}`\n"
                  f"**目录**: {_collapse_path(cwd)}")
    elements = [{"tag": "div",
                 "text": {"tag": "lark_md", "content": content_md}}]
    if preview:
        elements.append({"tag": "note", "elements": [
            {"tag": "plain_text", "content": _truncate(preview, 300)}
        ]})
    actions = [
        {"tag": "button", "text": {"tag": "plain_text", "content": "✅ 放行"},
         "type": "primary",
         "value": {"action": "approve", "request_id": rid}},
        {"tag": "button", "text": {"tag": "plain_text", "content": "❌ 拒绝"},
         "type": "danger",
         "value": {"action": "deny", "request_id": rid}},
    ]
    fb = _focus_button(focus_url)
    if fb:
        actions.append(fb)
    elements.append({"tag": "action", "actions": actions})
    return {
        "config": {"wide_screen_mode": True},
        "header": {"template": "purple",
                   "title": {"tag": "plain_text", "content": title}},
        "elements": elements,
    }


def build_ask_card(rid: str, question: str, options: list[str],
                   cwd: str, focus_url: Optional[str]) -> dict:
    actions = []
    for i, opt in enumerate(options[:4]):
        actions.append({
            "tag": "button",
            "text": {"tag": "plain_text",
                     "content": f"{i+1}. {_truncate(opt, 24)}"},
            "type": "default",
            "value": {"action": "pick", "request_id": rid,
                      "index": i, "label": opt},
        })
    # Single "fallback to local" button: resolves the request with local,
    # hook exits 0, Claude Code's native menu fires in iTerm. A pure URL
    # button (just focus iTerm) makes no sense here — user would still
    # be stuck since the hook is holding the AskUserQuestion invocation.
    actions.append({
        "tag": "button",
        "text": {"tag": "plain_text", "content": "💻 回电脑选"},
        "type": "default",
        "value": {"action": "local", "request_id": rid},
    })
    content_md = f"**问题**: {_truncate(question, 400)}"
    if cwd:
        content_md += f"\n**目录**: {_collapse_path(cwd)}"
    return {
        "config": {"wide_screen_mode": True},
        "header": {"template": "blue",
                   "title": {"tag": "plain_text",
                             "content": "🙋 Claude 有个问题要你选"}},
        "elements": [
            {"tag": "div", "text": {"tag": "lark_md", "content": content_md}},
            {"tag": "action", "actions": actions},
        ],
    }


def build_notify_card(text: str, cwd: str, focus_url: Optional[str]) -> dict:
    elements = [{"tag": "div",
                 "text": {"tag": "lark_md", "content": text}}]
    if cwd:
        elements.append({"tag": "note", "elements": [
            {"tag": "plain_text", "content": f"📂 {_collapse_path(cwd)}"}
        ]})
    actions = []
    fb = _focus_button(focus_url)
    if fb:
        actions.append(fb)
    actions.append({
        "tag": "button",
        "text": {"tag": "plain_text", "content": "🙅 我先忙"},
        "type": "default",
        "value": {"action": "dismiss"},
    })
    elements.append({"tag": "action", "actions": actions})
    return {
        "config": {"wide_screen_mode": True},
        "header": {"template": "blue",
                   "title": {"tag": "plain_text", "content": "🐾 Claude 找你呢"}},
        "elements": elements,
    }


def send_card(card: dict, tag: str = "") -> Optional[str]:
    proc = subprocess.run(
        ["lark-cli", "im", "+messages-send",
         "--user-id", OPEN_ID,
         "--msg-type", "interactive",
         "--content", json.dumps(card, ensure_ascii=False),
         "--as", "bot"],
        capture_output=True, text=True, timeout=15,
    )
    if proc.returncode != 0:
        log(f"send_card[{tag}] rc={proc.returncode}: {proc.stderr.strip()[:200]}")
        return None
    try:
        out = json.loads(proc.stdout)
        mid = out.get("data", {}).get("message_id") or out.get("message_id")
        log(f"send_card[{tag}] ok mid={mid}")
        return mid
    except Exception as e:
        log(f"send_card[{tag}] parse fail: {e} stdout={proc.stdout[:200]}")
        return None


def urgent(message_id: str):
    try:
        subprocess.run(
            ["lark-cli", "api", "PATCH",
             f"/open-apis/im/v1/messages/{message_id}/urgent_app",
             "--params", '{"user_id_type":"open_id"}',
             "--data", json.dumps({"user_id_list": [OPEN_ID]}),
             "--as", "bot"],
            capture_output=True, text=True, timeout=10,
        )
    except Exception as e:
        log(f"urgent fail: {e}")


def build_result_card(scenario: str, decision: str, summary: str,
                      pick_label: Optional[str] = None) -> dict:
    if decision == "approve":
        title, template = "✅ 放行！Claude 继续干活", "green"
        body = f"🐾 已批准 Claude {summary}" if summary else "🐾 已批准"
    elif decision == "pick":
        title, template = "✅ 选好啦", "green"
        body = f"🙋 帮 Claude 选了「{pick_label}」"
    elif decision == "local":
        title, template = "💻 回电脑处理", "grey"
        body = "让 Claude 在终端里再问一次吧"
    else:
        title, template = "❌ 拦住了～", "grey"
        body = f"🙅 没让 Claude {summary}" if summary else "🙅 已拦下"
    return {
        "config": {"wide_screen_mode": True},
        "header": {"template": template,
                   "title": {"tag": "plain_text", "content": title}},
        "elements": [
            {"tag": "div", "text": {"tag": "lark_md", "content": body}},
        ],
    }


def update_card_result(message_id: str, scenario: str, decision: str,
                        summary: str, pick_label: Optional[str] = None):
    card = build_result_card(scenario, decision, summary, pick_label)
    _patch_card(message_id, card, f"decision={decision}")


def build_dismissed_notify_card(original: dict) -> dict:
    """Grey-ify the original notify card. Preserve URL buttons (e.g. 🖥️切回
    iTerm) so the user still has an escape hatch after dismissing; drop
    event-triggering buttons (like 🙅 我先忙 itself) since tapping them again
    is a no-op. Preserves original title and body text."""
    card = json.loads(json.dumps(original))  # deep copy
    card.setdefault("header", {})["template"] = "grey"
    new_elements = []
    for el in card.get("elements", []):
        if el.get("tag") != "action":
            new_elements.append(el)
            continue
        kept = [b for b in el.get("actions", []) if b.get("url")]
        if kept:
            new_elements.append({"tag": "action", "actions": kept})
        new_elements.append({
            "tag": "note",
            "elements": [{"tag": "plain_text",
                          "content": "🙅 已忽略，忙完再回来看～"}],
        })
    card["elements"] = new_elements
    return card


def update_card_dismissed(message_id: str, original: dict):
    card = build_dismissed_notify_card(original)
    _patch_card(message_id, card, "decision=dismiss")


def _patch_card(message_id: str, card: dict, tag: str):
    try:
        proc = subprocess.run(
            ["lark-cli", "api", "PATCH",
             f"/open-apis/im/v1/messages/{message_id}",
             "--data", json.dumps({"content": json.dumps(card, ensure_ascii=False)}),
             "--as", "bot"],
            capture_output=True, text=True, timeout=10,
        )
        if proc.returncode != 0:
            log(f"update_card rc={proc.returncode} err={proc.stderr[:200]} "
                f"out={proc.stdout[:200]}")
        else:
            log(f"update_card ok mid={message_id} {tag}")
    except Exception as e:
        log(f"update_card fail: {e}")


def subscribe_loop():
    global _subscribe_alive
    backoff = 1.0
    while True:
        try:
            log("subscribe: starting lark-cli event +subscribe")
            proc = subprocess.Popen(
                ["lark-cli", "event", "+subscribe",
                 "--event-types", "card.action.trigger",
                 "--as", "bot"],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
            )
            _subscribe_alive = True
            backoff = 1.0
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                if not line.startswith("{"):
                    log(f"subscribe[status]: {line[:120]}")
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                header = obj.get("header", {})
                if header.get("event_type") != "card.action.trigger":
                    continue
                value = (obj.get("event", {})
                         .get("action", {}).get("value", {}) or {})
                rid = value.get("request_id")
                choice = value.get("action")
                # "dismiss" on notify cards — PATCH the original card to grey
                # + drop buttons, preserving the body so user still sees what
                # Claude was pinging about.
                if choice == "dismiss":
                    msg_id = (obj.get("event", {})
                              .get("context", {}).get("open_message_id"))
                    log(f"subscribe: notify dismissed mid={msg_id}")
                    if msg_id:
                        with notify_cards_lock:
                            original = notify_cards.pop(msg_id, None)
                        if original:
                            threading.Thread(
                                target=update_card_dismissed,
                                args=(msg_id, original),
                                daemon=True,
                            ).start()
                        else:
                            log(f"subscribe: no cached card for mid={msg_id}")
                    continue
                if not rid or choice not in ("approve", "deny", "pick", "local"):
                    log(f"subscribe: malformed event value={value}")
                    continue
                with pending_lock:
                    p = pending.get(rid)
                if not p:
                    log(f"subscribe: no pending for rid={rid} (expired?)")
                    continue
                if choice == "pick":
                    p.pick_index = value.get("index")
                    p.pick_label = value.get("label")
                p.decision = choice
                p.event.set()
                log(f"subscribe: resolved rid={rid} choice={choice} "
                    f"pick={p.pick_label}")
                if p.card_message_id:
                    threading.Thread(
                        target=update_card_result,
                        args=(p.card_message_id, p.scenario, choice,
                              p.summary, p.pick_label),
                        daemon=True,
                    ).start()
            rc = proc.wait()
            _subscribe_alive = False
            log(f"subscribe: exited rc={rc}")
        except Exception as e:
            _subscribe_alive = False
            log(f"subscribe: crash {e}")
        time.sleep(backoff)
        backoff = min(backoff * 2, 30.0)


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status: int, body: dict):
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            with pending_lock:
                n = len(pending)
            return self._reply(200, {
                "subscribe_alive": _subscribe_alive,
                "pending": n,
                "uptime": int(time.time() - _start_time),
            })
        if self.path == "/presence":
            return self._reply(200, {"at_computer": at_computer()})
        return self._reply(404, {"error": "not found"})

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        if not length:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def do_POST(self):
        try:
            if self.path == "/approve":
                return self._handle_approve()
            if self.path == "/notify":
                return self._handle_notify()
            if self.path == "/cancel-pending":
                return self._handle_cancel_pending()
            return self._reply(404, {"error": "not found"})
        except json.JSONDecodeError:
            return self._reply(400, {"error": "bad json"})
        except Exception as e:
            log(f"POST {self.path} crashed: {e}")
            return self._reply(500, {"error": str(e)})

    def _handle_approve(self):
        body = self._read_body()
        scenario = body.get("scenario", "bash")
        cwd = body.get("cwd", "")
        focus_url = body.get("iterm_focus_url") or None

        if at_computer():
            log(f"/approve scenario={scenario} -> local (at computer)")
            return self._reply(200, {"decision": "local"})

        rid = uuid.uuid4().hex[:12]
        if scenario == "bash":
            b = body.get("bash", {})
            cmd = b.get("cmd", "")
            if not cmd:
                return self._reply(400, {"error": "bash.cmd required"})
            humanized = b.get("humanized", "")
            card = build_bash_card(rid, cmd, humanized, cwd, focus_url)
            summary = humanized or "跑这条命令"
        elif scenario == "write_edit":
            w = body.get("write_edit", {})
            fp = w.get("file_path", "")
            if not fp:
                return self._reply(400, {"error": "write_edit.file_path required"})
            tool = w.get("tool", "Edit")
            preview = w.get("preview", "")
            card = build_write_edit_card(rid, tool, fp, preview, cwd, focus_url)
            summary = f"改 {os.path.basename(fp)}"
        elif scenario == "ask":
            a = body.get("ask", {})
            q = a.get("question", "")
            opts = a.get("options", [])
            if not q or not opts:
                return self._reply(400, {"error": "ask.question and options required"})
            card = build_ask_card(rid, q, opts, cwd, focus_url)
            summary = "回答问题"
        else:
            return self._reply(400, {"error": f"unknown scenario: {scenario}"})

        p = Pending(scenario=scenario, summary=summary,
                    deadline=time.time() + DEADLINE_SECS)
        with pending_lock:
            pending[rid] = p
        try:
            mid = send_card(card, tag=f"{scenario}/{rid}")
            if mid is None:
                return self._reply(502, {"error": "send_card failed"})
            p.card_message_id = mid
            urgent(mid)
            remaining = max(1.0, p.deadline - time.time())
            p.event.wait(timeout=remaining)
            if p.decision is None:
                decision = "timeout"
            elif p.decision == "pick":
                decision = "ask_pick"
            else:
                decision = p.decision
            log(f"/approve rid={rid} scenario={scenario} decision={decision}")
            resp = {"decision": decision, "rid": rid}
            if decision == "ask_pick":
                resp["pick"] = {"index": p.pick_index, "label": p.pick_label}
            return self._reply(200, resp)
        finally:
            with pending_lock:
                pending.pop(rid, None)

    def _handle_notify(self):
        body = self._read_body()
        text = body.get("text", "")
        if not text:
            return self._reply(400, {"error": "text required"})
        cwd = body.get("cwd", "")
        focus_url = body.get("iterm_focus_url") or None
        do_urgent = bool(body.get("urgent", False))
        silence_if_at_computer = bool(body.get("silence_if_at_computer", False))

        # Only silence "permission/attention" notifications (fire at t=0 when
        # local menu appears — user is looking at it). But schedule a follow-up:
        # if user is still idle 60s later and hasn't resolved the menu, ping
        # the phone. Cancelled by /cancel-pending from PostToolUse /
        # UserPromptSubmit hooks.
        if silence_if_at_computer and at_computer():
            tid = uuid.uuid4().hex[:8]

            def fire_followup():
                with followup_lock:
                    followup_timers.pop(tid, None)
                log(f"/notify follow-up fires tid={tid}")
                card = build_notify_card(text, cwd, focus_url)
                mid = send_card(card, tag=f"followup/{tid}")
                if mid:
                    with notify_cards_lock:
                        notify_cards[mid] = card
                    if do_urgent:
                        urgent(mid)

            timer = threading.Timer(FOLLOWUP_DELAY, fire_followup)
            timer.daemon = True
            with followup_lock:
                # Keep only one active follow-up — a newer notify supersedes
                # any older pending one.
                for t in followup_timers.values():
                    t.cancel()
                followup_timers.clear()
                followup_timers[tid] = timer
            timer.start()
            log(f"/notify silenced, follow-up scheduled in {FOLLOWUP_DELAY}s "
                f"tid={tid}")
            return self._reply(200, {
                "skipped": "at_computer",
                "follow_up_in": FOLLOWUP_DELAY,
                "timer_id": tid,
            })

        card = build_notify_card(text, cwd, focus_url)
        mid = send_card(card, tag="notify")
        if mid is None:
            return self._reply(502, {"error": "send_card failed"})
        with notify_cards_lock:
            notify_cards[mid] = card
        if do_urgent:
            urgent(mid)
        return self._reply(200, {"message_id": mid})

    def _handle_cancel_pending(self):
        """Cancel any scheduled follow-up timers. Called from PostToolUse and
        UserPromptSubmit hooks when user resolves the pending menu or starts
        new work — signals they're engaged, no need to ping the phone."""
        with followup_lock:
            n = len(followup_timers)
            for t in followup_timers.values():
                t.cancel()
            followup_timers.clear()
        if n:
            log(f"/cancel-pending -> cancelled {n} follow-up timer(s)")
        return self._reply(200, {"cancelled": n})

    def log_message(self, fmt, *args):
        log(f"http {self.address_string()} {fmt % args}")


def main():
    sys.stdout = open(LOG_PATH, "a", buffering=1)
    sys.stderr = sys.stdout
    log(f"daemon v3 starting on {HOST}:{PORT}")

    threading.Thread(target=subscribe_loop, daemon=True).start()

    server = ThreadingHTTPServer((HOST, PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
