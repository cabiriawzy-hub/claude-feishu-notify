---
name: claude-feishu-notify
description: 一键装 Claude Code 的飞书远控（V2）——Claude 卡在权限确认、改文件、AskUserQuestion 多选、空闲等输入，或遇到 API 错误时，往用户飞书私聊推可交互卡片，用户在手机上点按钮就能批准/拒绝/选选项让 Claude 接着跑。自动判断用户在不在电脑前：在就走本地菜单（不打扰），走开了才推卡片。使用场景：用户说"帮我装飞书远控""飞书 V2""在手机上批准 Claude""lark notify""setup lark remote"之类。
---

# Claude Feishu Notify V2

装一套 Claude Code 钩子 + 一个常驻 daemon（`ccr` = Claude Code Remote），把 Claude "停下来要你处理" 的信号推到飞书**可交互卡片**，用户直接在手机上点按钮就能让 Claude 接着跑。

## V2 vs V1

V1 是"喇叭"（只通知），V2 是"遥控器"：

- **🔴 Bash 命令** → 红色卡片，✅ 批准 / ❌ 拒绝
- **🟣 Edit/Write 文件** → 紫色卡片带 diff，✅ 放行 / ❌ 拒绝
- **🔵 AskUserQuestion 单选** → 蓝色卡片，每个选项一个按钮
- **🔔 空闲/API 错误** → 蓝色通知卡，不阻塞 Claude（V1 就有，升级成带「🖥️ 切回 iTerm」URL 按钮）
- **自动 presence 检测**：用户在用终端 → 走本地菜单（零打扰）；走开了 → 推飞书。靠 macOS `lsappinfo` 判断前台 app

## 核心文件

- `~/.claude/skills/claude-feishu-notify/ccr-daemon.py`（常驻 HTTP 服务，127.0.0.1:19837，带 `__OPEN_ID__` 占位符）
- `~/.claude/skills/claude-feishu-notify/claude-ccr.sh`（PreToolUse hook，分发 Bash/Write/Edit/AskUserQuestion 到 daemon）
- `~/.claude/skills/claude-feishu-notify/claude-notify.sh`（Notification hook，POST 到 daemon 的 `/notify`）
- `~/.claude/skills/claude-feishu-notify/claude-error-notify.sh`（Stop hook，API 错误专用，带占位符）
- `~/.claude/skills/claude-feishu-notify/claude-focus-daemon.py`（可选：iTerm2 点击切回）
- `~/.claude/skills/claude-feishu-notify/ccr`（CLI 工具）
- 安装后 hook + daemon 脚本会落到 `~/.claude/hooks/`（填好 open_id）
- `~/Library/LaunchAgents/com.claude.ccr.plist`（daemon 开机自启）
- `~/.claude/settings.json` 里注册 5 个 hook：`Notification` / `Stop` / `UserPromptSubmit` / `PreToolUse` / `PostToolUse`

## 安装流程

按顺序跑下面的 checklist，每一步失败就给用户清楚的修复指令，再等用户回来确认。

### 1. 依赖检查

```bash
command -v lark-cli && command -v jq
uname -s     # 必须是 Darwin (macOS)；Linux/Windows 不支持
python3 -c 'import sys; assert sys.version_info >= (3,9)'
```

- `lark-cli` 缺：告诉用户"需要先装 lark-cli 才能发消息"。官方文档：https://bytedance.larkoffice.com/docx/WnHkdJQM6oGpQFxm9i7ckVdenSh 。安装：https://bytedance.larkoffice.com/wiki/P6DiwXsrZiMYBOk2ikzc9Btanee 。
- `jq` 缺：`brew install jq`。
- 非 macOS：告诉用户"`ccr` daemon 只支持 macOS（靠 `lsappinfo` 做前台检测），你这个系统跑不了。要么换 V1 版本（纯通知）要么跳过"，停止流程。

### 2. 飞书登录 + 拿 open_id

```bash
lark-cli auth status
```

输出是 JSON，解析：
- `.tokenStatus == "valid"`：OK
- `.userOpenId`：用户自己的 open_id
- 其他情况（`expired` / `missing`）：让用户 `lark-cli auth login`

拿到 open_id 后，用 `AskUserQuestion` 跟用户确认一次（显示检测到的 userName + openId 前 8 位）。

### 3. 铺脚本到 ~/.claude/hooks/

```bash
mkdir -p ~/.claude/hooks

# 带 OPEN_ID 占位符的文件 → sed 替换
for f in ccr-daemon.py claude-error-notify.sh; do
  sed "s|__OPEN_ID__|${OPEN_ID}|g" \
    ~/.claude/skills/claude-feishu-notify/$f \
    > ~/.claude/hooks/$f
  chmod +x ~/.claude/hooks/$f
done

# 无占位符的文件 → 直接拷
for f in claude-ccr.sh claude-notify.sh ccr; do
  cp ~/.claude/skills/claude-feishu-notify/$f ~/.claude/hooks/$f
  chmod +x ~/.claude/hooks/$f
done
```

如果目标文件已存在且里面的 `OPEN_ID` 跟当前检测到的不一样，用 `AskUserQuestion` 让用户选：覆盖 / 保留旧的 / 取消。

### 4. 装 ccr daemon LaunchAgent

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.claude.ccr.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.ccr</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$HOME/.claude/hooks/ccr-daemon.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/ccr-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/ccr-daemon.log</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF

# 幂等加载
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.ccr.plist 2>/dev/null || true
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.claude.ccr.plist

sleep 2
curl -sS -m 3 http://127.0.0.1:19837/healthz
# 期望：{"subscribe_alive": true, "pending": 0, "uptime": 2}
```

判定：
- 返回 JSON 且 `subscribe_alive: true` → daemon 起来了，事件订阅也连上了
- `subscribe_alive: false` → daemon 跑起来但 `lark-cli event +subscribe` 没连上（常见：用户的 bot 权限没开 `im:message` 订阅），用户按钮点了 daemon 收不到，告诉用户去飞书开发者后台加订阅
- 连接失败 → 看 `/tmp/ccr-daemon.log`

### 5. 注册 5 个 hook 到 settings.json

**绝对不能**清掉用户已有的其他 hook / 权限 / 插件配置。用 jq 幂等合并：

```bash
SETTINGS=~/.claude/settings.json
NOTIFY_HOOK=~/.claude/hooks/claude-notify.sh
ERROR_HOOK=~/.claude/hooks/claude-error-notify.sh
CCR_HOOK=~/.claude/hooks/claude-ccr.sh
MARKER_CLEAR="rm -f /tmp/claude-notify-active.marker"
CANCEL_PENDING="curl -sS -m 2 -X POST http://127.0.0.1:19837/cancel-pending >/dev/null 2>&1 || true"
PRE_MATCHER="Bash|Write|Edit|AskUserQuestion"

[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

jq --arg nh "$NOTIFY_HOOK" --arg eh "$ERROR_HOOK" --arg ch "$CCR_HOOK" \
   --arg mc "$MARKER_CLEAR" --arg cp "$CANCEL_PENDING" --arg pm "$PRE_MATCHER" '
  .hooks //= {}

  # Notification → claude-notify.sh
  | .hooks.Notification //= []
  | (if any(.hooks.Notification[]?.hooks[]?; .command == $nh) then .
     else .hooks.Notification += [{"hooks":[{"type":"command","command":$nh}]}] end)

  # Stop → claude-error-notify.sh
  | .hooks.Stop //= []
  | (if any(.hooks.Stop[]?.hooks[]?; .command == $eh) then .
     else .hooks.Stop += [{"hooks":[{"type":"command","command":$eh}]}] end)

  # UserPromptSubmit → clear marker + cancel daemon follow-ups
  | .hooks.UserPromptSubmit //= []
  | (if any(.hooks.UserPromptSubmit[]?.hooks[]?; .command == $mc) then .
     else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$mc}]}] end)
  | (if any(.hooks.UserPromptSubmit[]?.hooks[]?; .command == $cp) then .
     else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$cp}]}] end)

  # PreToolUse (matcher Bash|Write|Edit|AskUserQuestion) → claude-ccr.sh
  | .hooks.PreToolUse //= []
  | (if any(.hooks.PreToolUse[]?; .matcher == $pm and any(.hooks[]?; .command == $ch))
     then .
     else .hooks.PreToolUse += [{"matcher":$pm,"hooks":[{"type":"command","command":$ch}]}]
     end)

  # PostToolUse (matcher Bash|Write|Edit|AskUserQuestion) → cancel daemon follow-ups
  | .hooks.PostToolUse //= []
  | (if any(.hooks.PostToolUse[]?; .matcher == $pm and any(.hooks[]?; .command == $cp))
     then .
     else .hooks.PostToolUse += [{"matcher":$pm,"hooks":[{"type":"command","command":$cp}]}]
     end)
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
```

### 6. 可选：iTerm2 点击切回 daemon

**只对 macOS + iTerm2 生效**。问用户「你用 iTerm2 吗？装了就能在飞书卡片上点一下直接切回对应的终端会话」。

用户选"装"，按顺序执行（跟 V1 相同）：

```bash
cp ~/.claude/skills/claude-feishu-notify/claude-focus-daemon.py ~/.claude/hooks/claude-focus-daemon.py
chmod +x ~/.claude/hooks/claude-focus-daemon.py

cat > ~/Library/LaunchAgents/com.claude.focus-daemon.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.focus-daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$HOME/.claude/hooks/claude-focus-daemon.py</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/claude-focus-daemon.log</string>
    <key>StandardErrorPath</key><string>/tmp/claude-focus-daemon.log</string>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF

launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist 2>/dev/null || true
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist

sleep 1
curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:47823/focus?id=00000000-0000-0000-0000-000000000000"
# 期望 404 = daemon 活着
```

### 7. 端到端测试

**测试 1：Notification 钩子**（权限场景，必须触发加急）

```bash
rm -f /tmp/claude-notify-active.marker
printf '{"message":"Claude needs your permission to use Bash","cwd":"%s","transcript_path":""}' \
  "$HOME" | ~/.claude/hooks/claude-notify.sh
echo "exit=$?"
tail -15 /tmp/claude-notify.log
```

期望：飞书收到「🐾 Claude 想...，同意一下喽～」消息（或因为 at_computer 被 skip 等 60s 推 followup 卡）。

**测试 2：Stop 钩子**（API 错误，跟 V1 完全一致）

```bash
cat > /tmp/test-error-transcript.jsonl <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"Request too large (max 32MB)."}]}}
EOF
printf '{"transcript_path":"/tmp/test-error-transcript.jsonl","cwd":"%s"}' "$HOME" \
  | ~/.claude/hooks/claude-error-notify.sh
tail -10 /tmp/claude-notify.log
rm -f /tmp/test-error-transcript.jsonl
```

**测试 3：ccr daemon 可交互卡片**（V2 核心）

```bash
# 模拟 Bash PreToolUse
cat > /tmp/test-ccr-payload.json <<'EOF'
{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/ccr-test-dir"},"cwd":"/tmp"}
EOF

# 这会等用户在飞书上点按钮（最多 10 分钟）
~/.claude/hooks/claude-ccr.sh < /tmp/test-ccr-payload.json
echo "exit=$?"
```

期望：
- 如果**终端在前台**：daemon 返 `local`，hook exit 0，无卡片（符合设计——在电脑前不打扰）
- 如果**切走了/锁屏**：飞书收到红色「⚠️ Claude 想跑高风险命令」卡片，带命令 + 目录 + 翻译 + ✅批准/❌拒绝

测试前台短路：用户在终端前跑；测试远程审批：跑之前让用户切到飞书 app 或锁屏。

### 8. 收尾

告诉用户：
- ✅ 装好了，打开飞书看两条测试消息
- daemon 日志：`/tmp/ccr-daemon.log`；hook 日志：`/tmp/ccr-approve.log`、`/tmp/claude-notify.log`
- 命令行控制：`ccr status / ccr enable / ccr disable / ccr restart / ccr log`（如果没加到 PATH，用 `~/.claude/hooks/ccr`）
- 临时不想被打扰：`ccr disable`
- 卸载：参考 README.md

## 注意事项

- **必须 `--as bot`**：用户身份缺 `im:message.send_as_user` scope（企业管控），只能用应用身份。
- **订阅权限**：V2 的卡片按钮回传靠 `lark-cli event +subscribe --event-types card.action.trigger`，飞书应用需要开事件订阅（通常已开）。没开的话用户按钮点了 daemon 收不到，表现为卡片一直转菊花直到 10 分钟超时。`ccr status` 里的 `subscribe_alive` 会显示。
- **加急需要应用权限**：同 V1。
- **AskUserQuestion 只处理单问**：`questions.length == 1` 才推卡片；多问 hook 直接 exit 0 走本地菜单。
- **并发会话**：一个 daemon 服务所有 Claude Code 会话，请求之间用 `rid` 隔离，卡片天然分开。
- **OPEN_ID 硬编码到 ccr-daemon.py + claude-error-notify.sh**：用户换账号要重跑 Skill。
- **点击切回只支持 iTerm2**。
