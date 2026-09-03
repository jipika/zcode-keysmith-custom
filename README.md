# zcode-keysmith-custom

ZCode 桌面端的**定制版 system-role 注入方案**，基于 [Jia-Ethan/zcode-keysmith](https://github.com/Jia-Ethan/zcode-keysmith)（MIT）改造。在原版能力之上增加了三件原版没有的东西：

| 能力 | 说明 |
| --- | --- |
| **注入总开关** | `~/.zcode-keysmith/DISABLED` 文件存在即不注入；`/po off` / `/po on` 秒切，无需重启 ZCode |
| **通道跳过** | `skip-channels.txt` 关键词子串匹配（默认 `offpeak`、`start-plan`）；官方送的闲时/体验算力通道永远不注入，避免 `request has been blocked due to unusual activity` 风控拦截 |
| **中性提示词** | 自带 `examples/zcode-unrestricted.md`（去人格化交付规则版），不含任何角色扮演/人格绑定内容 |

注入机制：`launchd` 环境变量把 ZCode 的 agent-server 指向定制 wrapper → wrapper 缓存并修补 ZCode runtime 的 `customSystemPrompt` 入口 → `system-role.md` 以 `injectionTarget: "system"` 进入 system message。**不修改 ZCode.app 原包，不读取 API key。**

```
LaunchAgent ─▶ launchctl env ─▶ zcode-agent-wrapper.py
                                   ├─ 检查 DISABLED（总开关）
                                   ├─ 缓存 runtime，按 modelRef/offPeak 标记匹配 skip-channels.txt
                                   └─ 修补 customSystemPrompt ─▶ ~/.zcode-keysmith/system-role.md
```

## macOS 快速开始

```bash
git clone https://github.com/jipika/zcode-keysmith-custom.git
cd zcode-keysmith-custom
./install.sh --dry-run     # 预览
./install.sh --yes         # 安装并激活
```

安装后**完全退出 ZCode（⌘Q）再重开**，新建任务即生效。

## 日常使用

```bash
/po status   # 查看注入开关
/po on       # 开启注入（下一个新会话生效）
/po off      # 关闭注入（恢复默认干净状态）
```

或直接调用 wrapper：

```bash
python3 ~/.zcode-keysmith/bin/zcode-agent-wrapper.py status|enable|disable
```

换提示词内容：编辑 `~/.zcode-keysmith/system-role.md`（或重跑 `./install.sh --yes --` 前设置 `KEYSMITH_SYSTEM_SOURCE=/path/to/your.md`）。

换跳过通道：编辑 `~/.zcode-keysmith/skip-channels.txt`，一行一个关键词，即改即生效。

## 卸载

```bash
./install.sh --uninstall --yes
```

受管文件全部改名 `.bak_*` 保留，launchd 环境清空，重启 ZCode 后回到原生状态。

## 观测与排障

| 路径 | 内容 |
| --- | --- |
| `~/.zcode-keysmith/logs/wrapper-start.jsonl` | 每次 agent-server 经 wrapper 启动的记录 |
| `~/.zcode-keysmith/logs/config-keys.jsonl` | 每次请求的通道判别记录（`mref`/`dis`/`skip` 字段）|
| `~/.zcode-keysmith/DISABLED` | 总开关文件（存在=关闭注入）|

排障要点：

- 注入不生效 → ZCode 主进程没真退出（关窗口≠退出，必须 ⌘Q）；
- 闲时任务报 `unusual activity` → 确认用的是本仓库 wrapper（含 skip 逻辑），并重启 ZCode；
- `/po` 未注册 → 命令文件需重启/新会话后加载。

## 与上游的关系

- 上游：[zcode-keysmith](https://github.com/Jia-Ethan/zcode-keysmith)（MIT License，含 Pier 人格示例提示词，注意别误用）
- 本仓库改动：wrapper 增加开关与通道跳过（`handle_toggle`、`probe`、`skip` 表达式）、安装脚本化、提示词中性化
- 同系列上游项目：[codex-keysmith](https://github.com/Jia-Ethan/codex-keysmith) / [claude-keysmith](https://github.com/Jia-Ethan/claude-keysmith) / [grok-keysmith](https://github.com/Jia-Ethan/grok-keysmith)

## AI 自动安装

把 [docs/agent-install.md](docs/agent-install.md) 的提示词整段发给你的 AI 编码助手（ZCode / Codex / Claude Code），它会自动完成克隆、安装、验证。

## License

MIT（继承上游）。本仓库 wrapper 仅操作本机 launchd 环境与用户目录文件，不读取、不存储 API key / token / MCP 配置。
