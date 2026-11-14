# TokenBar

macOS 菜单栏小工具，查看 Codex、Claude Code、Gemini CLI、Muse Code 的 token 用量。
纯本地：只读取各 CLI 写在磁盘上的会话日志，不联网，不调用任何私有接口，不读取 OAuth 令牌。

- 原生 Swift / SwiftUI（`MenuBarExtra`），macOS 13+，无第三方依赖，无 Dock 图标
- 每个提供方支持多个账户（不同的配置目录）
- 菜单栏显示紧凑数字（如 `1.2M`），点开后按提供方、账户显示 今日 / 近 7 天 / 本月 的 输入、输出、缓存、合计
- Codex 的本地日志带有限额百分比与重置时间，会显示为额度条（5 小时、每周）
- 增量解析（记住每个文件的读取偏移），在后台线程运行；默认每 60 秒刷新

## 构建与运行（需要 macOS 13+ 与 Xcode 15 / Swift 5.9+）

```bash
scripts/build-app.sh          # 生成 build/TokenBar.app（Release，ad-hoc 签名，LSUIElement）
open build/TokenBar.app
```

首次打开如被 Gatekeeper 拦截：在 Finder 中右键 TokenBar.app → 打开。
开发时也可以直接 `swift run TokenBar`。

核心库与测试可在任意平台（含 Linux）编译：

```bash
swift build --target TokenBarCore
swift test
```

## 添加账户

首次启动会自动检测默认账户（`~/.claude`、`~/.config/claude`、`~/.codex`、`~/.gemini`、
`~/.local/share/muse/sessions`，以及环境变量 `CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`MUSE_SESSIONS_DIR`、`XDG_DATA_HOME` 指向的目录）。
注意从 Finder/Dock 启动的应用看不到终端里的环境变量，非默认目录请手动添加。

1. 点击菜单栏图标 → “设置…” → “账户”。
2. 在对应提供方下点击“添加 … 账户”，填写名称，选择或输入数据目录：

| 提供方 | 数据目录应填写 | 实际读取 |
| --- | --- | --- |
| Claude Code | 配置目录，如 `~/.claude` 或另一个 `CLAUDE_CONFIG_DIR` | `<目录>/projects/**/*.jsonl` |
| Codex | `CODEX_HOME`，如 `~/.codex` | `<目录>/sessions/**`、`<目录>/archived_sessions` |
| Gemini CLI | `~/.gemini` | `<目录>/tmp/*/chats/**/session-*.json[l]` |
| Muse Code | sessions 目录，如 `~/.local/share/muse/sessions` | `<目录>/**/session.jsonl` |

3. 可以随时重命名、删除账户（删除只影响 TokenBar 的配置，不会删除任何日志）。

配置保存在 `~/Library/Application Support/TokenBar/config.json`。
API Key（目前没有任何提供方需要）如果将来启用，只会存放在钥匙串，不会写入该文件。

## 统计口径

- 输入 = 不含缓存命中的输入；输出 = 输出（含推理 token）；缓存 = 缓存读取 + 缓存写入；合计 = 以上全部。
- 菜单栏数字默认不含缓存（缓存读取通常远大于其他项），可在“通用”中改为包含。
- “今日 / 本月”按本机时区的自然日、自然月；“近 7 天”为含今天的 7 个自然日。
- Claude 按 `message.id + requestId` 去重；Codex 由累计值求差；Gemini 按会话 + 消息 id 去重；Muse 按 stream + sequence 去重。

## 已知限制

- Claude Code 与 Gemini CLI 的本地日志没有额度信息，因此不显示额度条。
- Muse Code 的额度需要调用 Meta 的私有接口并使用 CLI 的 OAuth 令牌，TokenBar 不会这样做；只统计本地 token。
- Muse Code 为闭源软件，日志格式来自第三方工具的逆向，Meta 未公开，可能随版本变化。
- Codex 的 fork / 恢复会话会继承父会话的累计值；TokenBar 对每个文件的第一条记录使用单次用量，其余按累计差值，极端情况下可能与官方统计有出入。
- 不计算费用，只统计 token。
