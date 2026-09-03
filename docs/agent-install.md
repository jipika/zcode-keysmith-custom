# AI 自动安装指南（发给你的 AI 编码助手）

把下面的提示词**整段复制**给正在运行的 AI 编码助手（ZCode、Codex CLI、Claude Code 等均可），助手会自动完成克隆、安装、验证，并在完成后提醒你重启。支持 macOS 与 Windows 10/11，助手按平台自动选择安装脚本。

---

## 提示词（复制这段）

```text
请使用 https://github.com/jipika/zcode-keysmith-custom 为本机 ZCode 桌面端安装
managed system-role 注入入口（含注入总开关与 offpeak/start-plan 通道跳过）。
先判断当前操作系统，再按对应平台分支执行。

执行要求：
1. 前置检查：
   - 先确认平台：macOS 还是 Windows。只执行与你平台匹配的分支，不要跨平台执行。
   - macOS：本机存在 /Applications/ZCode.app（自定义路径用 ZCODE_APP_PATH 环境变量）；
     python3 可用；runtime 中的 customSystemPrompt 锚点存在。
   - Windows：能找到 ZCode.exe（install.ps1 会自动探测运行进程/常见安装目录，
     探测不到时用 -ZCodeAppPath 参数指定）；python 3.10+ 可用（安装后不能删除）。
2. 安装（按平台二选一）：
   - git clone https://github.com/jipika/zcode-keysmith-custom.git 到临时目录；
   - macOS：cd 进入仓库后执行 ./install.sh --dry-run，把预览结果展示给我；
     确认无误后执行 ./install.sh --yes。
   - Windows：cd 进入仓库后执行
     powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun，
     把预览结果展示给我；确认无误后执行 ... -File .\install.ps1 -Yes。
   安装内容包括：
   - ~/.zcode-keysmith/system-role.md（注入源提示词，默认中性版）；
   - ~/.zcode-keysmith/skip-channels.txt（offpeak / start-plan 永不注入）；
   - ~/.zcode-keysmith/bin/zcode-agent-wrapper.py（带 DISABLED 总开关与通道跳过的 wrapper）；
   - ~/.zcode-keysmith/config.json、bin/zcode-keysmith-env.sh（macOS）
     或 bin/zcode-keysmith-env.ps1（Windows，可选手动重建 HKCU 环境变量）；
   - macOS：~/Library/LaunchAgents/com.jia.zcode-keysmith.env.plist；
   - 斜杠命令 ~/.zcode/commands/po.md（/po on|off|status）。
3. 验证（安装脚本会自动执行，请复核输出）：
   - macOS：launchctl getenv ZCODE_AGENT_SERVER_COMMAND 输出 wrapper 路径；
     python3 ~/.zcode-keysmith/bin/zcode-agent-wrapper.py status 显示"已开启 enabled"。
   - Windows：[Environment]::GetEnvironmentVariable('ZCODE_AGENT_SERVER_COMMAND','User')
     输出 python 路径；
     python %USERPROFILE%\.zcode-keysmith\bin\zcode-agent-wrapper.py status
     显示"已开启 enabled"。
4. 安全边界：
   - 不修改 ZCode.app 原包（macOS）/ ZCode 安装目录（Windows）；
   - 不读取、不存储、不打印 API key、token、cookie 或 MCP 配置；
   - 所有被替换文件先改名 .bak_* 备份，不直接删除。
5. 收尾：
   - 提醒我：完全退出 ZCode（macOS ⌘Q / Windows 托盘 Quit，关窗口不算）再重开，
     下一个新任务开始注入；
   - 告诉我日常开关用 /po on | /po off | /po status，即时生效无需重启；
   - 提示我：官方送的算力通道（offpeak-idle-plan / bigmodel-start-plan）无论开关状态
     都会自动跳过注入，避免 unusual activity 风控拦截。
6. 如需卸载：macOS 执行 ./install.sh --uninstall --yes；
   Windows 执行 powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall -Yes。
```

---

## 助手执行流程对照表

### macOS

| 步骤 | 命令 | 预期结果 |
| --- | --- | --- |
| 预览 | `./install.sh --dry-run` | 列出 8 个写入目标，`dry-run complete` |
| 安装 | `./install.sh --yes` | 逐文件 `wrote:` + 激活 + `== verify ==` |
| 开关自检 | `python3 ~/.zcode-keysmith/bin/zcode-agent-wrapper.py status` | `已开启 enabled` |
| 生效验证 | 重启 ZCode 后新会话发起任务 | `~/.zcode-keysmith/logs/wrapper-start.jsonl` 出现新记录 |

### Windows

| 步骤 | 命令 | 预期结果 |
| --- | --- | --- |
| 预览 | `powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun` | 列出写入目标，`dry-run complete` |
| 安装 | `powershell -ExecutionPolicy Bypass -File .\install.ps1 -Yes` | 逐文件 `wrote:` + HKCU 设置 + `== verify ==` |
| 开关自检 | `python %USERPROFILE%\.zcode-keysmith\bin\zcode-agent-wrapper.py status` | `已开启 enabled` |
| 环境检查 | `[Environment]::GetEnvironmentVariable('ZCODE_AGENT_SERVER_COMMAND','User')` | 输出 python.exe 路径 |
| 生效验证 | 完全退出 ZCode 后新会话发起任务 | `%USERPROFILE%\.zcode-keysmith\logs\wrapper-start.jsonl` 出现新记录 |

## 常见问题（助手排障用）

- **`runtime entrypoint shape not recognized`**：ZCode 版本更新导致锚点变化，检查 `zcode.cjs` 中 `customSystemPrompt` 是否仍存在（macOS：`/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs`；Windows：`<ZCode 安装目录>\resources\glm\zcode.cjs`）。
- **注入未生效**：ZCode 主进程未真退出。macOS：`launchctl getenv` 为空说明 launchd 域未激活，重跑 `sh ~/.zcode-keysmith/bin/zcode-keysmith-env.sh`；Windows：确认用户环境变量非空且 ZCode 在安装后才启动。
- **Windows 提示找不到 python**：`ZCODE_AGENT_SERVER_COMMAND` 记录的是安装时的 python 路径；Python 被移动/删除需重跑 `install.ps1 -Yes` 重新指向。
- **闲时任务仍报 `unusual activity`**：确认 agent-server 是经本仓库 wrapper 启动的（`wrapper-start.jsonl` 有记录且 runtime 带 skip 表达式），并完全重启 ZCode。
- **`/po` 命令不存在**：命令文件在安装后需重启或新会话才被注册。
