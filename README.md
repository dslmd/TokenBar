# TokenBar

macOS 菜单栏小工具，查看 Codex、Claude Code、Gemini CLI、Muse Code 的 token 用量与额度。

- 原生 Swift / SwiftUI（`MenuBarExtra`），macOS 13+，无第三方依赖，无 Dock 图标
- 每个提供方支持多个账户（不同的配置目录）
- token 统计完全来自本地日志（只读，不联网）
- 额度（5 小时 / 每周等）：Codex、Claude Code、Gemini CLI 支持**在线额度**（见下文“联网说明”），Codex 另有本地日志中的额度作为备用
- 菜单栏：图标 + 紧凑数字（如 `1.2M`），任一额度超过 90% 时图标变为警告标志；可只显示图标
- 弹窗：按提供方（可折叠）、账户显示 今日大数字、近 7 天、本月、输入/输出/缓存占比、7 天柱状图、额度条与重置倒计时
- 增量解析（记住每个文件的读取偏移），在后台线程运行；默认每 60 秒刷新

## 构建与运行（需要 macOS 13+ 与 Xcode 14.1+ / Swift 5.7+）

```bash
scripts/build-app.sh            # 生成 build/TokenBar.app（Release，自动生成图标，ad-hoc 签名，LSUIElement）
scripts/build-app.sh --install  # 同时复制到 /Applications（不带参数时会询问）
open build/TokenBar.app
```

首次打开如被 Gatekeeper 拦截：在 Finder 中右键 TokenBar.app → 打开。
每次重新构建都会得到新的 ad-hoc 签名，钥匙串授权（见下）需要重新点一次“始终允许”。
开发时也可以直接 `swift run TokenBar`。

快捷键（弹窗打开时）：⌘R 刷新，⌘, 设置，⌘Q 退出。

核心库与测试可在任意平台（含 Linux）编译：

```bash
swift build --target TokenBarCore
swift test
```

## 添加账户

首次启动会自动检测默认账户（`~/.claude`、`~/.config/claude`、`~/.codex`、`~/.gemini`、
`~/.local/share/muse/sessions`，以及环境变量 `CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`MUSE_SESSIONS_DIR`、`XDG_DATA_HOME` 指向的目录）。
注意从 Finder/Dock 启动的应用看不到终端里的环境变量，非默认目录请手动添加。

1. 点击菜单栏图标 → ⚙ → “账户”。
2. 在对应提供方下点击“添加 … 账户”，填写名称，选择或输入数据目录（下方会实时提示该目录是否像一个有效的数据目录）：

| 提供方 | 数据目录应填写 | 实际读取 |
| --- | --- | --- |
| Claude Code | 配置目录，如 `~/.claude` 或另一个 `CLAUDE_CONFIG_DIR` | `<目录>/projects/**/*.jsonl` |
| Codex | `CODEX_HOME`，如 `~/.codex` | `<目录>/sessions/**`、`<目录>/archived_sessions` |
| Gemini CLI | `~/.gemini` | `<目录>/tmp/*/chats/**/session-*.json[l]` |
| Muse Code | sessions 目录，如 `~/.local/share/muse/sessions` | `<目录>/**/session.jsonl` |

3. 可以随时重命名、删除账户（删除只影响 TokenBar 的配置，不会删除任何日志）。
4. “通用”里可设置登录时自动启动、刷新间隔、菜单栏显示方式。

配置保存在 `~/Library/Application Support/TokenBar/config.json`，不含任何令牌或密钥。

## 联网说明（在线额度）

默认开启“在线额度”（设置 → 通用 → 在线额度；每个账户也可单独关闭）。开启时 TokenBar 会读取**各 CLI 已经保存的登录凭据**，并向以下地址发请求，**至少间隔 5 分钟**（手动刷新最短 30 秒），失败后指数退避（5 分钟起，最长 1 小时）：

| 提供方 | 凭据位置 | 请求 |
| --- | --- | --- |
| Claude Code | `<配置目录>/.credentials.json`；默认账户还会读钥匙串项 `Claude Code-credentials`，其他配置目录会尝试 `Claude Code-credentials-<目录 SHA-256 前 8 位>`（未经官方确认） | `GET api.anthropic.com/api/oauth/usage`；续期 `POST platform.claude.com/v1/oauth/token` |
| Codex | `<CODEX_HOME>/auth.json` | `GET chatgpt.com/backend-api/wham/usage`（不续期） |
| Gemini CLI | `<~/.gemini>/oauth_creds.json` | `POST cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`、`:retrieveUserQuota`；续期 `POST oauth2.googleapis.com/token` |
| Muse Code | — | 暂无（不联网，仅本地 token） |

这些接口都是各 CLI 自用的非公开接口，可能随时变化。关闭“在线额度”后 TokenBar 完全不联网，行为与纯本地模式一致。令牌不会被写入日志或显示在界面上。

### 登录过期与自动续期

- **Claude Code / Gemini CLI**：访问令牌过期（或收到 401）时，TokenBar 会用刷新令牌续期，**重试一次**。因为刷新令牌可能轮换，续期遵循严格流程：先重新读取 CLI 的凭据（如果 CLI 已经续期就直接采用）；先确认凭据存储可写（文件可写 / 钥匙串允许更新）才会续期；写回时保留所有未知字段，文件采用“临时文件 + 重命名”原子写入并保留权限（0600）；写入前再比对一次，CLI 抢先更新则不覆盖。Gemini 续期需要 Gemini CLI 自带的 OAuth 客户端信息，TokenBar 从已安装的 CLI 里读取（也可用环境变量 `GEMINI_OAUTH_CLIENT_ID` / `GEMINI_OAUTH_CLIENT_SECRET`）；找不到时提示“运行一次 gemini 即可恢复”。
- **Codex**：与 CodexBar 一致，TokenBar **不会**自己续期 Codex 的登录（CLI 独占刷新令牌）。过期时显示“登录已过期，运行一次 codex 即可恢复”，CLI 续期后下次刷新自动恢复。
- 无法安全写回时（文件不可写、钥匙串拒绝）不会续期，显示“运行一次 claude/gemini 即可恢复”。
- Claude Code 在 macOS 上通常把凭据放在钥匙串：首次读取会弹出授权窗口，请选“始终允许”。选“拒绝”后不会再自动弹窗，手动点刷新才会重试。
- 网络或认证失败只会在卡片上显示一行小提示，**不会影响本地 token 数字**；最近一次成功的额度会继续显示。

## 统计口径

- 输入 = 不含缓存命中的输入；输出 = 输出（含推理 token）；缓存 = 缓存读取 + 缓存写入。
- 卡片与菜单栏的数字默认不含缓存（缓存读取通常远大于其他项），可在“通用”中改为包含。
- “今日 / 本月”按本机时区的自然日、自然月；“近 7 天”为含今天的 7 个自然日（柱状图同此）。
- Claude 按 `message.id + requestId` 去重；Codex 由累计值求差；Gemini 按会话 + 消息 id 去重；Muse 按 stream + sequence 去重。

## 已知限制

- Muse Code 为闭源软件，日志格式来自第三方工具的逆向，可能随版本变化；其额度接口的响应结构无法从公开资料确认，所以不做在线额度。
- Gemini CLI 较新版本可能把登录凭据放进钥匙串而不是 `oauth_creds.json`，这种情况下无法读取在线额度。
- Codex 的 fork / 恢复会话会继承父会话的累计值，极端情况下与官方统计有出入。
- 不计算费用，只统计 token。
