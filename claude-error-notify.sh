#!/usr/bin/env bash
# Claude Code Stop hook → Lark message on API errors only.
# Catches things like "Request too large (max 32MB)" that never trigger
# the idle Notification hook because the request fails before Claude waits.
# Installed by the claude-feishu-notify skill. Edit OPEN_ID at the top if it changes.
set -euo pipefail

[[ "${CLAUDE_NOTIFY_DISABLE:-}" == "1" ]] && exit 0

OPEN_ID="__OPEN_ID__"
LOG="/tmp/claude-notify.log"
IDLE_MARKER="/tmp/claude-notify-active.marker"
SEEN_DIR="/tmp/claude-notify-seen"
mkdir -p "$SEEN_DIR"

payload=$(cat || true)
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null || echo "")

[[ -z "$transcript" || ! -f "$transcript" ]] && exit 0

# On API errors, Claude Code often doesn't fire Stop until the user /compacts
# or retries — by which point a plain `tail -30` has moved past the error record.
# Widen the window and filter by timestamp + isApiErrorMessage, then dedup by uuid
# so we never double-fire on the same error.
cutoff_iso=$(date -u -v-10M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || date -u -d '10 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
  || echo "")

last=$(tail -300 "$transcript" 2>/dev/null \
  | jq -c --arg cutoff "$cutoff_iso" \
      'select(.type == "assistant" and .isApiErrorMessage == true and (($cutoff == "") or ((.timestamp // "") > $cutoff)))' \
      2>/dev/null \
  | tail -1)

[[ -z "$last" ]] && exit 0

err_uuid=$(printf '%s' "$last" | jq -r '.uuid // ""' 2>/dev/null)
if [[ -n "$err_uuid" ]]; then
  seen_file="${SEEN_DIR}/${err_uuid}"
  [[ -f "$seen_file" ]] && exit 0
  touch "$seen_file"
  find "$SEEN_DIR" -type f -mtime +7 -delete 2>/dev/null || true
fi

err_text=$(printf '%s' "$last" | jq -r '.message.content[0].text // ""' 2>/dev/null)

friendly=""
case "$err_text" in
  *"Request too large"*|*"max 32MB"*|*"request_too_large"*)
    friendly="🚨 请求太大（超过 32MB），Claude 卡住啦——按两下 Esc 回上一步，或清掉一些大文件/长输出再继续"
    ;;
  *"rate_limit"*|*"Rate limit"*|*"rate limit"*)
    friendly="🚦 API 限流了，等几分钟再让 Claude 接着干"
    ;;
  *"overloaded"*|*"Overloaded"*)
    friendly="🔥 Claude API 过载，等一会儿重试"
    ;;
  *"context_length"*|*"context length"*|*"maximum context"*)
    friendly="📦 上下文满了，开个新会话或 /compact 一下"
    ;;
  *)
    clean=$(printf '%s' "$err_text" | tr '\n' ' ' | head -c 120)
    friendly="⚠️ Claude API 报错：${clean}"
    ;;
esac

project=""
if [[ -n "$cwd" ]]; then
  if [[ "$cwd" == "$HOME" ]]; then
    project="~"
  elif [[ "$cwd" == "$HOME/"* ]]; then
    project="~/${cwd#$HOME/}"
  else
    project="$cwd"
  fi
fi

if [[ -n "$project" ]]; then
  text="${friendly} 📂 ${project}"
else
  text="${friendly}"
fi

# iTerm2 click-to-focus: append localhost URL handled by claude-focus-daemon.
if [[ "${TERM_PROGRAM:-}" == "iTerm.app" && -n "${ITERM_SESSION_ID:-}" ]]; then
  uuid="${ITERM_SESSION_ID##*:}"
  if [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    text="${text}"$'\n'"🖥️ [点这里切回来](http://localhost:47823/focus?id=${uuid})"
  fi
fi

{
  echo "=== $(date '+%F %T') [error-notify] ==="
  echo "uuid: $err_uuid"
  echo "err: $(printf '%s' "$err_text" | head -c 200)"
  echo "sent: $text"
  resp=$(lark-cli im +messages-send \
    --user-id "$OPEN_ID" \
    --markdown "$text" \
    --as bot 2>&1) || true
  printf '%s\n' "$resp" | head -5

  mid=$(printf '%s' "$resp" | jq -r '.data.message_id // .message_id // empty' 2>/dev/null)
  if [[ -n "$mid" ]]; then
    echo "urgent_app for $mid"
    lark-cli api PATCH "/open-apis/im/v1/messages/${mid}/urgent_app" \
      --params '{"user_id_type":"open_id"}' \
      --data "{\"user_id_list\":[\"${OPEN_ID}\"]}" \
      --as bot 2>&1 | head -5 || echo "(urgent failed)"
  else
    echo "(no message_id — skip urgent)"
  fi
} >> "$LOG" 2>&1

touch "$IDLE_MARKER"
exit 0
