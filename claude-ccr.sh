#!/usr/bin/env bash
# Claude Code Remote (ccr) PreToolUse dispatcher (v3).
#
# Routes risky tool invocations to the ccr daemon so the user can approve
# from Feishu when they're away from the computer. When at-computer the
# daemon short-circuits to {"decision":"local"} and we fall through to
# Claude Code's native local permission UI.
#
# Scenarios dispatched:
#   Bash            -> every command (no risk filter in v3)
#   Write / Edit    -> all file mutations
#   AskUserQuestion -> single-question forms (multi-question -> local)
#
# Disable switch: `touch /tmp/ccr-disabled.marker` (or `ccr disable`).
set -euo pipefail

DISABLED_MARKER="/tmp/ccr-disabled.marker"
# Marker written right before /approve so claude-notify.sh knows which tool
# is currently pending. Transcript's latest tool_use lags for AskUserQuestion
# (flushed only after answer), so notify would otherwise describe the
# previous tool. PostToolUse clears this marker.
PENDING_TOOL_MARKER="/tmp/ccr-pending-tool.json"
DAEMON="http://127.0.0.1:19837/approve"
LOG="/tmp/ccr-approve.log"

[[ -f "$DISABLED_MARKER" ]] && exit 0

payload=$(cat || true)
tool=$(printf '%s' "$payload" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null || echo "")

# iTerm click-to-focus URL (consumed by claude-focus-daemon on :47823).
focus_url=""
if [[ "${TERM_PROGRAM:-}" == "iTerm.app" && -n "${ITERM_SESSION_ID:-}" ]]; then
  uuid="${ITERM_SESSION_ID##*:}"
  if [[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    focus_url="http://localhost:47823/focus?id=${uuid}"
  fi
fi

# Translate a shell command into plain Chinese. Returns empty if no match.
# Kept in sync with claude-notify.sh:humanize_bash — duplicated intentionally
# so each hook stays self-contained.
humanize_bash() {
  local c="$1"
  c=$(printf '%s' "$c" | sed -E 's/^([[:space:]]*[A-Z_][A-Z0-9_]*=[^[:space:]]+[[:space:]]+)+//; s/^[[:space:]]+//')
  case "$c" in
    "rm -rf"*|"rm -fr"*|"rm "*"-rf"*|"rm "*"-fr"*) echo "⚠️ 删掉整个文件夹（不可逆！）" ;;
    "rm "*)                             echo "删文件" ;;
    "git push"*)                        echo "把代码推到远端" ;;
    "git pull"*|"git fetch"*)           echo "拉远端代码" ;;
    "git commit"*)                      echo "提交代码改动" ;;
    "git reset"*|"git revert"*|"git restore"*) echo "撤销改动" ;;
    "git checkout"*|"git switch"*)      echo "切分支" ;;
    "git merge"*)                       echo "合并分支" ;;
    "git rebase"*)                      echo "变基（整理提交记录）" ;;
    "git "*)                            echo "跑 git 命令" ;;
    "npm install"*|"npm i"|"npm i "*|\
    "pnpm install"*|"pnpm i"|"pnpm i "*|\
    "yarn install"*|"yarn")             echo "装项目依赖" ;;
    "npm run dev"*|"npm start"*)        echo "启动开发服务器" ;;
    "npm run build"*|"pnpm build"*)     echo "打包项目" ;;
    "npm run"*|"pnpm run"*|"bun run"*)  echo "跑项目脚本" ;;
    "curl "*)                           echo "访问网络/调接口" ;;
    "wget "*)                           echo "下载文件" ;;
    "mkdir "*)                          echo "新建文件夹" ;;
    "mv "*)                             echo "移动/重命名文件" ;;
    "cp "*)                             echo "复制文件" ;;
    "chmod "*|"chown "*)                echo "改文件权限" ;;
    "kill "*|"pkill "*|"killall "*)     echo "结束某个进程" ;;
    "brew install"*)                    echo "装软件" ;;
    "docker "*)                         echo "操作容器" ;;
    "ssh "*)                            echo "远程登录到别的电脑" ;;
    "gh pr"*)                           echo "操作 GitHub PR" ;;
    "gh "*)                             echo "操作 GitHub" ;;
    *)                                  echo "" ;;
  esac
}

# Build scenario payload for daemon.
build_body() {
  case "$tool" in
    Bash)
      local cmd humanized
      cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')
      [[ -z "$cmd" ]] && return 1
      humanized=$(humanize_bash "$cmd")
      jq -n --arg cwd "$cwd" --arg url "$focus_url" \
            --arg cmd "$cmd" --arg hum "$humanized" \
        '{scenario:"bash", cwd:$cwd, iterm_focus_url:$url,
          bash:{cmd:$cmd, humanized:$hum}}'
      ;;
    Write)
      local fp content preview
      fp=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""')
      [[ -z "$fp" ]] && return 1
      content=$(printf '%s' "$payload" | jq -r '.tool_input.content // ""')
      preview=$(printf '%s' "$content" | head -c 300)
      jq -n --arg cwd "$cwd" --arg url "$focus_url" \
            --arg fp "$fp" --arg preview "$preview" \
        '{scenario:"write_edit", cwd:$cwd, iterm_focus_url:$url,
          write_edit:{tool:"Write", file_path:$fp, preview:$preview}}'
      ;;
    Edit)
      local fp old new preview
      fp=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""')
      [[ -z "$fp" ]] && return 1
      old=$(printf '%s' "$payload" | jq -r '.tool_input.old_string // ""' | head -c 120)
      new=$(printf '%s' "$payload" | jq -r '.tool_input.new_string // ""' | head -c 120)
      preview="- ${old}"$'\n'"+ ${new}"
      jq -n --arg cwd "$cwd" --arg url "$focus_url" \
            --arg fp "$fp" --arg preview "$preview" \
        '{scenario:"write_edit", cwd:$cwd, iterm_focus_url:$url,
          write_edit:{tool:"Edit", file_path:$fp, preview:$preview}}'
      ;;
    AskUserQuestion)
      local n question options_json
      n=$(printf '%s' "$payload" | jq -r '.tool_input.questions | length')
      [[ "$n" != "1" ]] && return 1  # multi-question -> fall through to local
      question=$(printf '%s' "$payload" | jq -r '.tool_input.questions[0].question // ""')
      options_json=$(printf '%s' "$payload" | jq -c '[.tool_input.questions[0].options[].label]')
      [[ -z "$question" ]] && return 1
      jq -n --arg cwd "$cwd" --arg url "$focus_url" \
            --arg q "$question" --argjson opts "$options_json" \
        '{scenario:"ask", cwd:$cwd, iterm_focus_url:$url,
          ask:{question:$q, options:$opts}}'
      ;;
    *)
      return 1
      ;;
  esac
}

body=$(build_body) || exit 0

# Pre-compute humanized action text for claude-notify.sh. Kept here (not in
# notify) so it uses the EXACT tool_input that triggered this PreToolUse,
# avoiding the transcript-lag bug on AskUserQuestion.
action_text=""
case "$tool" in
  Bash)
    cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' | head -1)
    humanized=$(humanize_bash "$cmd")
    if [[ -n "$humanized" ]]; then
      action_text="$humanized"
    else
      action_text="跑 $(printf '%s' "$cmd" | cut -c1-40)"
    fi
    ;;
  Write|Edit)
    fp=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""')
    action_text="改 $(basename "$fp")"
    ;;
  AskUserQuestion)
    # Python handles UTF-8 char counting correctly (cut -c is byte-based on
    # default macOS locale, which mangles Chinese). 30 chars then … if longer.
    q=$(printf '%s' "$payload" \
      | jq -r '.tool_input.questions[0].question // ""' \
      | /usr/bin/python3 -c 'import sys; s=sys.stdin.read().strip().replace("\n"," "); print(s[:30] + ("…" if len(s)>30 else ""), end="")')
    action_text="问你「${q}」"
    ;;
esac
jq -n --arg tool "$tool" --arg action "$action_text" \
  '{tool:$tool, action:$action}' > "$PENDING_TOOL_MARKER" 2>/dev/null || true

{
  echo "=== $(date '+%F %T') ==="
  echo "tool: $tool"
  echo "body: $body"
} >> "$LOG"

resp=$(curl -sS --max-time 600 -X POST "$DAEMON" \
  -H 'Content-Type: application/json' \
  -d "$body" 2>>"$LOG" || echo '')
echo "resp: $resp" >> "$LOG"

decision=$(printf '%s' "$resp" | jq -r '.decision // "error"' 2>/dev/null || echo "error")

case "$decision" in
  local)
    # Fall through to Claude Code's native permission UI (at computer).
    exit 0
    ;;
  approve)
    # Explicit approve JSON — bypass Claude Code's local permission prompt,
    # otherwise the user sees both a phone card AND a terminal prompt.
    printf '{"decision":"approve","reason":"用户在飞书上批准"}\n'
    exit 0
    ;;
  deny)
    printf '{"decision":"block","reason":"用户在飞书上拒绝了这条操作"}\n'
    exit 2
    ;;
  timeout)
    printf '{"decision":"block","reason":"用户没在 10 分钟内回应飞书审批，默认拦截"}\n'
    exit 2
    ;;
  ask_pick)
    pick=$(printf '%s' "$resp" | jq -r '.pick.label // ""')
    idx=$(printf '%s' "$resp" | jq -r '.pick.index // 0')
    reason="用户在飞书上选择了第 $((idx+1)) 项：${pick}"
    printf '{"decision":"block","reason":%s}\n' "$(jq -Rn --arg r "$reason" '$r')"
    exit 2
    ;;
  *)
    # Daemon unreachable / malformed — fail-open to local permission.
    echo "ccr: daemon unreachable, falling through to local" >> "$LOG"
    exit 0
    ;;
esac
