---
description: keysmith 注入开关（默认关闭）：on=开启注入 / off=关闭注入 / status=查状态；无参数=自动切换
---

你在执行 keysmith 注入开关操作。当前设计：**默认不注入（像没装一样），只有手动开启后才注入**。严格按以下流程执行，不要做任何额外的事：

1. 确定参数。用户传入的参数是：$ARGUMENTS

2. 参数规范化：
   - `on` / `开` / `开启` → 执行开启（注入开启，直到下次关闭）
   - `off` / `关` / `关闭` → 执行关闭（恢复默认干净状态）
   - `status` / `状态` → 只查询状态
   - 参数为空 → 先执行第 3 步的 status 命令查看当前状态，然后执行与当前状态相反的操作，并把切换结果告诉用户

3. 对应的 shell 命令（用 Bash 工具执行）：
   - 开启：`python3 /Users/lixiongwei/.zcode-keysmith/bin/zcode-agent-wrapper.py enable`
   - 关闭：`python3 /Users/lixiongwei/.zcode-keysmith/bin/zcode-agent-wrapper.py disable`
   - 状态：`python3 /Users/lixiongwei/.zcode-keysmith/bin/zcode-agent-wrapper.py status`

4. 把命令的输出原样汇报给用户，并补一句生效说明："切换即时生效：开启后，从下一个新会话/任务开始注入；送的算力通道（offpeak/start-plan）无论开关状态都自动不注入"。

5. 如果参数无法识别（不是 on/off/status/空），列出合法用法后停止。
