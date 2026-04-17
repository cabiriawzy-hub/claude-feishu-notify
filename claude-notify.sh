#!/usr/bin/env bash
# Claude Code Notification hook → Feishu/Lark message (with urgent-app push).
# Installed by the claude-feishu-notify skill. Edit OPEN_ID at the top if it changes.
set -euo pipefail

[[ "${CLAUDE_NOTIFY_DISABLE:-}" == "1" ]] && exit 0

OPEN_ID="__OPEN_ID__"
MARKER="/tmp/claude-notify-active.marker"
LOG="/tmp/claude-notify.log"

[[ -f "$MARKER" ]] && exit 0

humanize_bash() {
  local c="$1"
  c=$(printf '%s' "$c" | sed -E 's/^([[:space:]]*[A-Z_][A-Z0-9_]*=[^[:space:]]+[[:space:]]+)+//; s/^[[:space:]]+//')
  case "$c" in
    "rm -rf"*)                          echo "⚠️ 删掉整个文件夹（不可逆！）" ;;
    "rm "*)                             echo "删文件" ;;
    "git push"*)                        echo "把代码推到远端" ;;
    "git pull"*|"git fetch"*)           echo "拉远端代码" ;;
    "git commit"*)                      echo "提交代码改动" ;;
    "git add"*)                         echo "暂存改动" ;;
    "git clone"*)                       echo "克隆仓库" ;;
    "git checkout"*|"git switch"*)      echo "切分支" ;;
    "git merge"*)                       echo "合并分支" ;;
    "git rebase"*)                      echo "变基（整理提交记录）" ;;
    "git reset"*|"git revert"*|"git restore"*) echo "撤销改动" ;;
    "git status"*|"git log"*|"git diff"*|"git show"*|"git branch"*) echo "看代码状态" ;;
    "git "*)                            echo "跑 git 命令" ;;
    "npm install"*|"npm i"*|"pnpm install"*|"yarn install"*|"yarn") echo "装项目依赖" ;;
    "npm run dev"*|"npm start"*|"npm run start"*) echo "启动开发服务器" ;;
    "npm run build"*|"pnpm build"*)     echo "打包项目" ;;
    "npm run typecheck"*|"npm run test"*|"npm test"*|"npm t"*) echo "跑测试/代码检查" ;;
    "npm run lint"*)                    echo "跑代码检查" ;;
    "npm run"*|"pnpm run"*|"bun run"*)  echo "跑项目脚本" ;;
    "npx "*|"bunx "*|"pnpx "*)          echo "临时跑个工具" ;;
    "curl "*)                           echo "访问网络/调接口" ;;
    "wget "*)                           echo "下载文件" ;;
    "mkdir "*)                          echo "新建文件夹" ;;
    "mv "*)                             echo "移动/重命名文件" ;;
    "cp "*)                             echo "复制文件" ;;
    "chmod "*|"chown "*)                echo "改文件权限" ;;
    "ln "*)                             echo "做快捷方式" ;;
    "lark-cli docs"*)                   echo "操作飞书文档" ;;
    "lark-cli wiki"*)                   echo "操作飞书 Wiki" ;;
    "lark-cli minutes"*)                echo "看飞书会议记录" ;;
    "lark-cli vc"*)                     echo "看飞书会议信息" ;;
    "lark-cli whiteboard"*)             echo "操作飞书画板" ;;
    "lark-cli im"*)                     echo "发/管飞书消息" ;;
    "lark-cli api"*)                    echo "调飞书接口" ;;
    "lark-cli auth"*)                   echo "飞书登录/授权" ;;
    "lark-cli schema"*)                 echo "查飞书接口定义" ;;
    "lark-cli "*)                       echo "跑飞书命令" ;;
    "python3 "*|"python "*)             echo "跑 Python 脚本" ;;
    "node "*)                           echo "跑 Node.js 脚本" ;;
    "bun "*)                            echo "跑 Bun 命令" ;;
    "pip install"*)                     echo "装 Python 包" ;;
    "pip "*)                            echo "管 Python 包" ;;
    "brew install"*)                    echo "装软件" ;;
    "brew "*)                           echo "管电脑软件" ;;
    "docker "*)                         echo "操作容器" ;;
    "ssh "*)                            echo "远程登录到别的电脑" ;;
    "kill "*|"pkill "*|"killall "*)     echo "结束某个进程" ;;
    "ps "*|"ps"|"top"|"htop")           echo "看正在跑的进程" ;;
    "ls"|"ls "*)                        echo "看文件列表" ;;
    "cat "*|"head "*|"tail "*|"bat "*)  echo "看文件内容" ;;
    "find "*|"fd "*)                    echo "查找文件" ;;
    "grep "*|"rg "*|"ack "*)            echo "搜关键字" ;;
    "open "*)                           echo "打开文件/网页" ;;
    "gh pr"*)                           echo "操作 GitHub PR" ;;
    "gh issue"*)                        echo "操作 GitHub Issue" ;;
    "gh "*)                             echo "操作 GitHub" ;;
    "firecrawl "*)                      echo "抓网页" ;;
    "claude "*|"claude")                echo "操作 Claude Code 本身" ;;
    "cd "*|"cd")                        echo "切目录" ;;
    "echo "*|"printf "*)                echo "打印点东西" ;;
    "sleep "*)                          echo "等一会儿" ;;
    "jq "*)                             echo "处理 JSON 数据" ;;
    *)                                  echo "" ;;
  esac
}

payload=$(cat || true)
raw_msg=$(printf '%s' "$payload" | jq -r '.message // ""' 2>/dev/null || echo "")
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null || echo "")
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")

perm_tool=""
if [[ "$raw_msg" == *"permission to use "* ]]; then
  perm_tool=$(printf '%s' "$raw_msg" | sed -E 's/.*permission to use ([A-Za-z_]+).*/\1/')
fi

action=""
last_tool=""
if [[ -n "$transcript" && -f "$transcript" ]]; then
  if [[ -n "$perm_tool" ]]; then
    last_tu=$(tail -200 "$transcript" 2>/dev/null \
      | jq -c --arg t "$perm_tool" 'select(.message.content? | type=="array") | .message.content[]? | select(.type=="tool_use" and .name == $t)' 2>/dev/null \
      | tail -1)
  else
    last_tu=$(tail -200 "$transcript" 2>/dev/null \
      | jq -c 'select(.message.content? | type=="array") | .message.content[]? | select(.type=="tool_use")' 2>/dev/null \
      | tail -1)
  fi
  if [[ -n "$last_tu" ]]; then
    tname=$(printf '%s' "$last_tu" | jq -r '.name // ""')
    last_tool="$tname"
    case "$tname" in
      Bash)
        cmd=$(printf '%s' "$last_tu" | jq -r '.input.command // ""' | head -1 | cut -c1-80)
        human=$(humanize_bash "$cmd")
        if [[ -n "$human" ]]; then
          action="$human"
        else
          action="跑 ${cmd}"
        fi
        ;;
      Edit|Write|NotebookEdit)
        fp=$(printf '%s' "$last_tu" | jq -r '.input.file_path // ""')
        action="改 $(basename "$fp")"
        ;;
      Read)
        fp=$(printf '%s' "$last_tu" | jq -r '.input.file_path // ""')
        action="看 $(basename "$fp")"
        ;;
      WebFetch)
        url=$(printf '%s' "$last_tu" | jq -r '.input.url // ""' | cut -c1-60)
        action="抓 ${url}"
        ;;
      WebSearch)
        q=$(printf '%s' "$last_tu" | jq -r '.input.query // ""' | cut -c1-40)
        action="搜 ${q}"
        ;;
      Glob|Grep)
        p=$(printf '%s' "$last_tu" | jq -r '.input.pattern // ""' | cut -c1-40)
        action="搜代码 ${p}"
        ;;
      AskUserQuestion)
        q=$(printf '%s' "$last_tu" | jq -r '.input.questions[0].question // ""' | cut -c1-50)
        action="问你「${q}」"
        ;;
      TaskCreate|TaskUpdate|TaskGet|TaskList)
        action="更新任务列表"
        ;;
      TaskOutput|TaskStop)
        action="管后台任务"
        ;;
      EnterPlanMode|ExitPlanMode)
        action="切换规划模式"
        ;;
      EnterWorktree|ExitWorktree)
        action="切工作分支目录"
        ;;
      Agent)
        action="派个子代理去干活"
        ;;
      Skill)
        action="调用一个 Skill"
        ;;
      mcp__*)
        action="调用 ${tname#mcp__}"
        ;;
      "")
        ;;
      *)
        action="${tname}"
        ;;
    esac
  fi
fi

friendly=""
urgent=0
case "$raw_msg" in
  *"permission to use "*)
    tool=$(printf '%s' "$raw_msg" | sed -E 's/.*permission to use ([A-Za-z_]+).*/\1/')
    if [[ -n "$action" ]]; then
      friendly="🐾 Claude 想${action}，同意一下喽～"
    else
      friendly="🐾 Claude 想用 ${tool} 干点小事，同意一下喽～"
    fi
    urgent=1
    ;;
  *"permission"*|*"Permission"*)
    if [[ -n "$action" ]]; then
      friendly="✋ Claude 想${action}，点个同意我就继续～"
    else
      friendly="✋ Claude 卡住啦，点个同意我就继续～"
    fi
    urgent=1
    ;;
  *"waiting for your input"*|*"waiting for input"*)
    if [[ "$last_tool" == "AskUserQuestion" ]]; then
      friendly="🙋 Claude ${action}，帮我选一个～"
      urgent=1
    else
      last_text=""
      if [[ -n "$transcript" && -f "$transcript" ]]; then
        last_text=$(tail -200 "$transcript" 2>/dev/null \
          | jq -c 'select(.type=="assistant") | . as $r | ([.message.content[]? | select(.type=="text") | .text] | join(" ")) as $t | select($t != "" and ($t | test("^No response requested\\.?$") | not)) | $t' 2>/dev/null \
          | tail -1 \
          | jq -r '.' 2>/dev/null \
          | tr -d '[:space:]' | tail -c 3)
      fi
      if [[ "$last_text" == *"?" || "$last_text" == *"？" ]]; then
        friendly="❓ Claude 问你问题呢，回个话～"
        urgent=1
      else
        friendly="💤 Claude 活干完摸鱼呢，来看看下一步？"
      fi
    fi
    ;;
  *"needs your attention"*|*"needs attention"*)
    if [[ "$last_tool" == "AskUserQuestion" ]]; then
      friendly="🙋 Claude ${action}，帮我选一个～"
    elif [[ -n "$action" ]]; then
      friendly="🔔 Claude 想${action}，过来看一眼～"
    else
      friendly="🔔 Claude 有事找你，过来看一眼～"
    fi
    urgent=1
    ;;
  "")
    friendly="👀 Claude 找不到你啦，回来呀～"
    ;;
  *)
    msg_clean=$(printf '%s' "$raw_msg" | sed -E 's/^[Cc]laude([[:space:]][Cc]ode)?[[:space:]]+//')
    friendly="🔔 Claude ${msg_clean}"
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

content=$(jq -n --arg t "$text" '{text:$t}')

{
  echo "=== $(date '+%F %T') ==="
  echo "raw: $raw_msg"
  echo "sent: $text"
  resp=$(lark-cli im +messages-send \
    --user-id "$OPEN_ID" \
    --msg-type text \
    --content "$content" \
    --as bot 2>&1) || true
  printf '%s\n' "$resp" | head -5

  if [[ "$urgent" == "1" ]]; then
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
  fi
} >> "$LOG" 2>&1

touch "$MARKER"
exit 0
