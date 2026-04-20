# claude-feishu-notify

Claude Code 卡住就推飞书——**而且直接在卡片上点按钮就能让 Claude 接着跑**。权限确认、改文件、AskUserQuestion 多选、空闲摸鱼、API 错误，全都能在手机飞书上拍板，不用跑回电脑。

> English version: [claude-lark-notify](https://github.com/cabiriawzy-hub/claude-lark-notify)

## V1 → V2 升级点

| | V1 | V2 |
|---|---|---|
| 飞书角色 | 📣 喇叭（只通知） | 🎮 遥控器（直接决策） |
| 权限确认 | 推文本提醒 | 推**可交互卡片**，✅ 批准 / ❌ 拒绝 |
| 改文件 | 不处理 | 紫色卡片带路径 + diff 预览，一键放行 |
| AskUserQuestion | 推文本提醒 | 蓝色卡片，每个选项一个按钮，点哪个 Claude 就按哪个继续 |
| 在电脑前 | 每次都推 | **自动判断**你在不在桌面前——在就沉默走本地菜单，走开了才推飞书 |
| 一键切回终端 | 消息里一个 markdown 链接 | 每张卡一个「🖥️ 切回 iTerm」URL 按钮 |

## 这是啥

一个 Claude Code [Skill](https://docs.claude.com/en/docs/claude-code/skills) + 一套钩子 + 一个常驻 daemon。装好之后：

**🔴 高风险命令**（Claude 想跑 Bash / 删文件 / git push）→ 红色卡片，带命令 + 目录 + 中文翻译 + ✅ 批准 / ❌ 拒绝按钮

**🟣 改/写文件**（Edit / Write）→ 紫色卡片，带文件路径 + diff 预览 + ✅ 放行 / ❌ 拒绝

**🔵 多选问题**（单问 AskUserQuestion）→ 蓝色卡片，每个选项一个按钮 + 💻 回电脑选

**🔔 空闲/问答/API 错误**（V1 就有）→ 蓝色通知卡，不阻塞 Claude，带 🖥️ 切回 iTerm / 🙅 我先忙

## 最丝滑的一点：智能判断你在不在桌面前

每次 Claude 要拍板前，daemon 都会偷偷判断一下：**你现在到底在不在桌面前用着终端？**

- ✅ **在用终端**（iTerm2 / Terminal / Ghostty / Alacritty / kitty / WezTerm 在前台）：飞书**一声不响**，走本地终端菜单，你按数字键就过。体验和原生 Claude Code 零差别。
- 🏃 **切走了 / 锁屏 / 在看别的 app**：飞书**直接推卡片**，手机点一下就继续。

关键是**自动切换、无感**——不用 `ccr start/stop` 开关远程模式。

## 依赖

- [Claude Code](https://claude.com/claude-code)
- [`lark-cli`](https://bytedance.larkoffice.com/docx/WnHkdJQM6oGpQFxm9i7ckVdenSh)（对外全量的飞书 CLI。安装：https://bytedance.larkoffice.com/wiki/P6DiwXsrZiMYBOk2ikzc9Btanee ）
- `jq`（`brew install jq`）
- macOS（Linux 不支持，`ccr` daemon 靠 `lsappinfo` 做前台检测）
- 飞书应用开了 `im:message.urgent` / `im:message.urgent:app_send` scope——不开也能用，只是消息不加急

## 一键安装

```bash
git clone https://github.com/cabiriawzy-hub/claude-feishu-notify.git \
  ~/.claude/skills/claude-feishu-notify
```

然后在 Claude Code 里说一句：

```
/claude-feishu-notify
```

或者口语："帮我装飞书 V2 / 帮我装飞书远控"。Claude 会自动：

1. 检查 `lark-cli` / `jq` / macOS
2. 从 `lark-cli auth status` 抽你的 `open_id` 并跟你确认
3. 把所有脚本填好 `open_id` 落到 `~/.claude/hooks/`
4. 装 **`ccr` daemon**：复制 `ccr-daemon.py` + 生成 LaunchAgent plist + `launchctl bootstrap`
5. 幂等合并 `~/.claude/settings.json`：`Notification` / `Stop` / `UserPromptSubmit` / `PreToolUse(Bash|Write|Edit|AskUserQuestion)` / `PostToolUse`
6. 发两条测试消息 + 加急，确认链路通

## `ccr` CLI

装好后 `~/.claude/hooks/ccr` 会给你几个常用命令（建议加到 PATH 或 alias）：

```bash
ccr status     # 看模式 + daemon 健康 + presence + 最近日志
ccr enable     # 启用远程审批（默认状态）
ccr disable    # 临时关掉——所有 hook 变 no-op，回归纯 Claude Code 原生 UI
ccr restart    # 卸载 + 重装 LaunchAgent
ccr log        # 实时看 daemon 日志
```

## 关掉 / 卸载

临时闭嘴：

```bash
ccr disable       # 软开关，hook 秒变 no-op
# 或
export CLAUDE_NOTIFY_DISABLE=1
```

永久卸载：

```bash
# 1. 卸 daemon
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.ccr.plist
rm ~/Library/LaunchAgents/com.claude.ccr.plist

# 2. 删 hook 脚本
rm ~/.claude/hooks/{ccr-daemon.py,claude-ccr.sh,claude-notify.sh,claude-error-notify.sh,ccr}

# 3. 从 ~/.claude/settings.json 里撤掉对应 hook 条目

# 4. 如果装了 iTerm2 点击切回 daemon，再跑：
launchctl bootout gui/$UID ~/Library/LaunchAgents/com.claude.focus-daemon.plist
rm ~/Library/LaunchAgents/com.claude.focus-daemon.plist ~/.claude/hooks/claude-focus-daemon.py
```

## 已知限制

- **macOS only**：`ccr` daemon 的前台检测靠 `lsappinfo`，Linux / Windows 跑不起来。
- **单会话设计**：daemon 监听 `127.0.0.1:19837`，一台机器一个 daemon 服务所有 Claude Code 会话。并发会话用 rid 隔离，卡片天然分开。
- **AskUserQuestion 只处理单问**：`questions.length == 1` 才推卡片；多问直接走本地菜单。
- **卡片等 10 分钟**：审批卡超时视为「拒绝」。通知卡不阻塞 Claude。
- **用户身份发不了消息**：飞书 `im:message.send_as_user` 通常被企业管控，固定用应用身份 `--as bot`。
- **加急需要应用权限**：`im:message.urgent` / `im:message.urgent:app_send` 常被企业管控，找管理员加白名单即可。消息发送本身不受影响。
- **点击切回只支持 iTerm2**：靠 `ITERM_SESSION_ID` env var；Terminal.app / Ghostty / WezTerm 里没这个 env var，卡片不会带「切回 iTerm」按钮，其他功能照常。

## 日志

- daemon：`/tmp/ccr-daemon.log`
- hook：`/tmp/ccr-approve.log`（PreToolUse） + `/tmp/claude-notify.log`（Notification/Stop）

有问题先翻这里。
