# claude-feishu-notify

Claude Code 卡住就推飞书——权限确认、AskUserQuestion、闲置等输入、文本提问、API 错误，都会往你飞书私聊发一条带加急的消息，让你别再错过。

> English version: [claude-lark-notify](https://github.com/cabiriawzy-hub/claude-lark-notify)

## 这是啥

一个 Claude Code [Skill](https://docs.claude.com/en/docs/claude-code/skills) + 两个钩子脚本。装好之后：

- **权限确认**（Claude 想跑个 Bash、抓个网页、删个文件）→ 秒推加急
- **AskUserQuestion** → 60 秒没回应推加急
- **文本提问**（Claude 最后一条消息以 `?` / `？` 结尾的）→ 60 秒没回应推加急
- **闲置摸鱼**（Claude 干完活等你下一步）→ 60 秒没回应推普通消息
- **API 错误**（请求过大 / 限流 / 过载 / 上下文满）→ `Stop` 钩子实时推加急
- 消息带**中文化的操作描述**（比如 `git push origin main` → "把代码推到远端"）和**项目路径**
- **iTerm2 点击切回**（可选，macOS 专用）→ 飞书消息里点一下「点这里切回来」，自动把对应的 iTerm2 会话拉到前台

## 依赖

- [Claude Code](https://claude.com/claude-code)
- [`lark-cli`](https://bytedance.larkoffice.com/docx/WnHkdJQM6oGpQFxm9i7ckVdenSh)（对外全量的飞书 CLI。安装文档：https://bytedance.larkoffice.com/wiki/P6DiwXsrZiMYBOk2ikzc9Btanee ）
- `jq`（`brew install jq`）
- 飞书应用已开 `im:message.urgent` 或 `im:message.urgent:app_send` scope——不开也能用，只是消息不会加急

## 一键安装

```bash
git clone https://github.com/cabiriawzy-hub/claude-feishu-notify.git \
  ~/.claude/skills/claude-feishu-notify
```

然后在 Claude Code 里说一句：

```
/claude-feishu-notify
```

或者口语："帮我装飞书提醒"。Claude 会自动：

1. 检查 `lark-cli` / `jq` 装了没、登录了没
2. 从 `lark-cli auth status` 抽你的 `open_id` 并跟你确认
3. 把钩子脚本填好 `open_id` 落到 `~/.claude/hooks/claude-notify.sh` 和 `~/.claude/hooks/claude-error-notify.sh`
4. 幂等合并进 `~/.claude/settings.json`（保留你已有的配置）
5. 发两条测试消息 + 加急，确认链路通

## 关掉 / 卸载

临时闭嘴：

```bash
export CLAUDE_NOTIFY_DISABLE=1
```

永久卸载：

```bash
rm ~/.claude/hooks/claude-notify.sh ~/.claude/hooks/claude-error-notify.sh
# 再从 ~/.claude/settings.json 里移除 Notification / Stop / UserPromptSubmit 的条目

# 如果装了 iTerm2 点击切回 daemon，再跑：
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist
rm ~/Library/LaunchAgents/com.claude.focus-daemon.plist ~/.claude/hooks/claude-focus-daemon.py
```

## 已知限制

- **Notification 不是实时**：Claude 问问题时钩子要等 ~60 秒空闲才响，秒答会绕过。权限确认是实时的。
- **用户身份发不了消息**：飞书 `im:message.send_as_user` 通常被企业管控，所以脚本固定用应用身份（`--as bot`）。
- **加急需要应用权限**：`im:message.urgent` / `im:message.urgent:app_send` 常被企业管控，可能要找管理员加白名单。
- **Stop 钩子每次停都会跑**：但脚本里过滤了——只有最后一条 assistant 记录带 `isApiErrorMessage=true` 才推，正常完成零噪音。
- **点击切回只支持 iTerm2**：靠 `ITERM_SESSION_ID` env var + iTerm2 AppleScript `unique id`。Terminal.app / Ghostty / WezTerm / SSH 里没这个 env var，消息不会带链接，hook 其他功能照常。

## 日志

所有发送记录都在 `/tmp/claude-notify.log`，有问题翻这里。
