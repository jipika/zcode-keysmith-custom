# AI 自动安装指南（发给你的 AI 编码助手）

把下面的提示词**整段复制**给正在运行的 AI 编码助手（ZCode、Codex CLI、Claude Code 等均可），助手会自动完成克隆、安装、验证，并在完成后提醒你重启。

---

## 提示词（复制这段）

```text
请使用 https://github.com/jipika/zcode-keysmith-custom 为本机 ZCode 桌面端安装
managed system-role 注入入口（含注入总开关与 offpeak/start-plan 通道跳过）。

执行要求：
1. 前置检查：
   - macOS，且本机存在 /Applications/ZCode.app（自定义路径用 ZCODE_APP_PATH 环境变量）；
   - python3 可用；runtime 中的 customSystemPrompt 锚点存在。
2. 安装：
   - git clone https://github.com/jipika/zcode-keysmith-custom.git 到临时目录；
   - cd 进入仓库后执行 ./install.sh --dry-run，把预览结果展示给我；
   - 确认无误后执行 ./install.sh --yes。
   安装内容包括：
   - ~/.zcode-keysmith/system-role.md（注入源提示词，默认中性版）；
   - ~/.zcode-keysmith/skip-channels.txt（offpeak / start-plan 永不注入）；
   - ~/.zcode-keysmith/bin/zcode-agent-wrapper.py（带 DISABLED 总开关与通道跳过的 wrapper）；
   - ~/.zcode-keysmith/config.json、bin/zcode-keysmith-env.sh；
   - ~/Library/LaunchAgents/com.jia.zcode-keysmith-custom.env.plist；
   - 斜杠命令 ~/.zcode/commands/po.md（/po on|off|status）。
3. 验证（安装脚本会自动执行，请复核输出）：
   - launchctl getenv ZCODE_AGENT_SERVER_COMMAND 输出 wrapper 路径；
   - python3 ~/.zcode-keysmith/bin/zcode-agent-wrapper.py status 显示"已开启 enabled"。
4. 安全边界：
   - 不修改 /Applications/ZCode.app 原包；
   - 不读取、不存储、不打印 API key、token、cookie 或 MCP 配置；
   - 所有被替换文件先改名 .bak_* 备份，不直接删除。
5. 收尾：
   - 提醒我：完全退出 ZCode（⌘Q，关窗口不算）再重开，下一个新任务开始注入；
   - 告诉我日常开关用 /po on | /po off | /po status，即时生效无需重启；
   - 提示我：官方送的算力通道（offpeak-idle-plan / bigmodel-start-plan）无论开关状态
     都会自动跳过注入，避免 unusual activity 风控拦截。
6. 如需卸载：在仓库目录执行 ./install.sh --uninstall --yes。
```

---

## 助手执行流程对照表

| 步骤 | 命令 | 预期结果 |
| --- | --- | --- |
| 预览 | `./install.sh --dry-run` | 列出 6 个写入目标，`dry-run complete` |
| 安装 | `./install.sh --yes` | 逐文件 `wrote:` + 激活 + `== verify ==` |
| 开关自检 | `python3 ~/.zcode-keysmith/bin/zcode-agent-wrapper.py status` | `已开启 enabled` |
| 开关测试 | `... disable` → `... status` → `... enable` | DISABLED 文件出现又消失，最终 `已开启` |
| 生效验证 | 重启 ZCode 后新会话发起任务 | `~/.zcode-keysmith/logs/wrapper-start.jsonl` 出现新记录 |

## 常见问题（助手排障用）

- **`runtime entrypoint shape not recognized`**：ZCode 版本更新导致锚点变化，检查 `zcode.cjs` 中 `customSystemPrompt` 是否仍存在。
- **注入未生效**：ZCode 主进程未真退出；`launchctl getenv` 为空说明 launchd 域未激活，重跑 `sh ~/.zcode-keysmith/bin/zcode-keysmith-env.sh`。
- **闲时任务仍报 `unusual activity`**：确认 agent-server 是经本仓库 wrapper 启动的（`wrapper-start.jsonl` 有记录且 runtime 带 skip 表达式），并重启 ZCode。
- **`/po` 命令不存在**：命令文件在安装后需重启或新会话才被注册。
