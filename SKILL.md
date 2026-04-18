---
name: claude-feishu-notify
description: 一键装 Claude Code 的飞书提醒钩子——Claude 卡在权限确认、AskUserQuestion、空闲等输入，或遇到 API 错误（如请求过大、限流、过载）时，往用户飞书私聊发带加急的消息。使用场景：用户说"每次 Claude 停下来叫我，发飞书提醒""飞书提醒""lark notify""setup lark notify"之类。
---

# Claude Feishu Notify

装两个 Claude Code 钩子，把 Claude "停下来要你处理" 的信号推到飞书：

1. **Notification 钩子**：权限确认、AskUserQuestion、空闲 60s 等输入时触发
2. **Stop 钩子**：Claude API 报错（Request too large / rate limit / overloaded 等）时触发

两种场景都会发带加急的飞书消息。

核心文件：
- `~/.claude/skills/claude-feishu-notify/claude-notify.sh`（Notification 模板，带 `__OPEN_ID__` 占位符）
- `~/.claude/skills/claude-feishu-notify/claude-error-notify.sh`（Stop 模板，同样带占位符）
- `~/.claude/skills/claude-feishu-notify/claude-focus-daemon.py`（可选：iTerm2 点击消息切回会话，macOS 专用）
- 安装后 hook 脚本会落到 `~/.claude/hooks/`（填好 open_id）
- `~/.claude/settings.json` 里注册 `Notification`、`Stop`、`UserPromptSubmit` 三个 hook

## 安装流程

按顺序跑下面的 checklist，每一步失败就给用户清楚的修复指令，再等用户回来确认。

### 1. 依赖检查

```bash
command -v lark-cli && command -v jq
```

- `lark-cli` 缺：告诉用户"需要先装 lark-cli 才能发消息"。官方介绍文档：https://bytedance.larkoffice.com/docx/WnHkdJQM6oGpQFxm9i7ckVdenSh 。安装文档：https://bytedance.larkoffice.com/wiki/P6DiwXsrZiMYBOk2ikzc9Btanee 。
- `jq` 缺：`brew install jq`。

### 2. 飞书登录 + 拿 open_id

```bash
lark-cli auth status
```

输出是 JSON，解析：
- `.tokenStatus == "valid"`：OK
- `.userOpenId`：用户自己的 open_id，拿来发消息和加急
- 其他情况（`expired` / `missing`）：让用户 `lark-cli auth login`，浏览器走完 OAuth 后回来重试

拿到 open_id 后，用 `AskUserQuestion` 跟用户确认一次（显示检测到的 userName + openId 前 8 位），避免装到别人名下。

### 3. 铺两个 hook 脚本

```bash
mkdir -p ~/.claude/hooks

for f in claude-notify.sh claude-error-notify.sh; do
  sed "s|__OPEN_ID__|${OPEN_ID}|g" \
    ~/.claude/skills/claude-feishu-notify/$f \
    > ~/.claude/hooks/$f
  chmod +x ~/.claude/hooks/$f
done
```

如果任一目标文件已经存在、且里面的 `OPEN_ID` 跟当前检测到的不一样，用 `AskUserQuestion` 让用户选：覆盖 / 保留旧的 / 取消。

### 4. 注册 hooks 到 settings.json

目标：在 `~/.claude/settings.json` 里加三条 hook：
- `hooks.Notification`：跑 `claude-notify.sh`
- `hooks.Stop`：跑 `claude-error-notify.sh`
- `hooks.UserPromptSubmit`：清 marker

**绝对不能**清掉用户已有的其他 hook / 权限 / 插件配置。用 jq 做幂等合并：

```bash
SETTINGS=~/.claude/settings.json
NOTIFY_HOOK=~/.claude/hooks/claude-notify.sh
ERROR_HOOK=~/.claude/hooks/claude-error-notify.sh
MARKER_CLEAR="rm -f /tmp/claude-notify-active.marker"

[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

jq --arg nh "$NOTIFY_HOOK" --arg eh "$ERROR_HOOK" --arg mc "$MARKER_CLEAR" '
  .hooks //= {} |
  .hooks.Notification //= [] |
  (if any(.hooks.Notification[]?.hooks[]?; .command == $nh)
   then .
   else .hooks.Notification += [{"hooks":[{"type":"command","command":$nh}]}]
   end) |
  .hooks.Stop //= [] |
  (if any(.hooks.Stop[]?.hooks[]?; .command == $eh)
   then .
   else .hooks.Stop += [{"hooks":[{"type":"command","command":$eh}]}]
   end) |
  .hooks.UserPromptSubmit //= [] |
  (if any(.hooks.UserPromptSubmit[]?.hooks[]?; .command == $mc)
   then .
   else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":$mc}]}]
   end)
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
```

### 5. 可选：装 iTerm2 点击切回会话 daemon

**只对 macOS + iTerm2 生效**。非 macOS 或用 Terminal.app / Ghostty / WezTerm 的，**跳过这一步**，hook 也不会在消息里加链接。

先问用户：「你用 iTerm2 吗？装了就能在飞书消息里点一下直接切回对应的终端会话。」用 `AskUserQuestion` 让用户选 装 / 跳过。

用户选"装"，按顺序执行：

```bash
# 拷贝 daemon 脚本到 hooks 目录
cp ~/.claude/skills/claude-feishu-notify/claude-focus-daemon.py ~/.claude/hooks/claude-focus-daemon.py
chmod +x ~/.claude/hooks/claude-focus-daemon.py

# 生成 launchd plist（每个用户路径不一样，所以现场生成）
mkdir -p ~/Library/LaunchAgents
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
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/claude-focus-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-focus-daemon.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

# 加载 launchd（如已加载先卸掉再装，幂等）
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist 2>/dev/null || true
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist

# 验证 daemon 起来了
sleep 1
curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:47823/focus?id=00000000-0000-0000-0000-000000000000"
# 期望输出 404（UUID 合法但 session 不存在），说明 daemon 活着
```

判定：
- 返回 `404` → daemon 跑起来了，告诉用户成功了
- 返回 `000` 或连接错误 → daemon 没起来，让用户看 `/tmp/claude-focus-daemon.log`
- 非 iTerm 环境，脚本自己会在 hook 里静默跳过，不会报错

### 6. 端到端测试

**Notification 钩子**（权限确认场景）：

```bash
rm -f /tmp/claude-notify-active.marker
printf '{"message":"Claude needs your permission to use Bash","cwd":"%s","transcript_path":""}' \
  "$HOME" | ~/.claude/hooks/claude-notify.sh
echo "exit=$?"
tail -15 /tmp/claude-notify.log
```

**Stop 钩子**（API 错误场景）：

```bash
rm -f /tmp/claude-notify-active.marker
cat > /tmp/test-error-transcript.jsonl <<'EOF'
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"Request too large (max 32MB). Double press esc to go back and try with a smaller file."}]}}
EOF
printf '{"transcript_path":"/tmp/test-error-transcript.jsonl","cwd":"%s"}' "$HOME" \
  | ~/.claude/hooks/claude-error-notify.sh
echo "exit=$?"
tail -15 /tmp/claude-notify.log
rm -f /tmp/test-error-transcript.jsonl
```

两条测试消息都要在飞书里看到。判定：
- 日志里有 `"ok": true` → 消息发成功
- 日志里有 `urgent_app for om_...` + `"code": 0` → 加急成功
- 日志里有 `(urgent failed)` 或 `permission_violations` → 加急权限没开，告诉用户：消息能发、但不会加急；想开加急要飞书开发者后台给应用加 `im:message.urgent` 或 `im:message.urgent:app_send` scope

### 7. 收尾

告诉用户：
- ✅ 装好了，让他们打开飞书找自己的私聊，应该能看到两条测试消息
- 日志在 `/tmp/claude-notify.log`，有问题翻这里
- 临时不想被打扰：`export CLAUDE_NOTIFY_DISABLE=1`
- 卸载：删 `~/.claude/hooks/claude-notify.sh`、`~/.claude/hooks/claude-error-notify.sh`，再从 `~/.claude/settings.json` 里撤掉三个 hook 条目
- 如果装了 iTerm2 点击切回 daemon，再跑：`launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist && rm ~/Library/LaunchAgents/com.claude.focus-daemon.plist ~/.claude/hooks/claude-focus-daemon.py`

## 注意事项

- **必须 `--as bot`**：用户身份缺 `im:message.send_as_user` scope（企业管控），能发的只有应用身份。
- **Notification 不是实时**：Claude 问问题时，钩子要等 ~60 秒空闲才响，不是秒发。这是 Claude Code 本身的行为，Skill 改不了。
- **Stop 钩子每次停都会跑**：但脚本里过滤了——只有最后一条 assistant 记录带 `isApiErrorMessage=true` 才推，正常完成零噪音。
- **加急需要应用权限**：`im:message.urgent` / `im:message.urgent:app_send` 常被企业管控，可能需要找管理员加白名单。消息发送本身不受影响。
- **OPEN_ID 硬编码**：模板把 open_id 直接 sed 进脚本，不读环境变量。用户换账号要重跑 Skill（或手改脚本顶部那行）。
- **点击切回只支持 iTerm2**：daemon 靠 `ITERM_SESSION_ID` env var + iTerm2 AppleScript `unique id`，Terminal.app / Ghostty / WezTerm / SSH 里没这个 env var，hook 自己会静默跳过。
