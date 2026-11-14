# TokenBar

macOS 菜单栏小工具，查看 Codex、Claude Code、Gemini CLI、Muse Code（Meta 的编程 CLI）的 token 用量与额度，以及 Meta 私人助理 Muse（muse.ai）的每周额度。界面为英文。

- 原生 Swift / SwiftUI（`MenuBarExtra`），macOS 13+，无第三方依赖，无 Dock 图标
- 每个提供方支持多个账户（不同的配置目录），**自动检测，无需手动填写路径**；也可以“登录另一个账户”
- token 统计完全来自本地日志（只读，不联网）
- 额度（5 小时 / 每周等）：Codex、Claude Code、Gemini CLI 支持**在线额度**（见下文“联网说明”），Codex 另有本地日志中的额度作为备用
- Muse（muse.ai，私人助理）：在 TokenBar 内登录后显示每周额度、套餐、剩余 token 与加购额度（非官方，见下文“Muse（muse.ai）”）
- 菜单栏：图标 + 紧凑数字（如 `1.2M`），任一额度超过 90% 时图标变为警告标志；可只显示图标
- 弹窗：按提供方（可折叠，顺序为 Claude Code、Codex、Gemini CLI、Muse、Muse Code）、账户显示 今日大数字、近 7 天、本月、输入/输出/缓存占比、7 天柱状图、额度条与重置倒计时；Muse 账户只有套餐、每周额度条与重置倒计时、剩余 token 和加购额度
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
Muse 的登录窗口使用系统自带的 WebKit（`WKWebView`，链接由 `import WebKit` 自动完成）；应用未启用沙盒，也没有启用 hardened runtime，因此不需要额外的 entitlement 或 Info.plist 项。

快捷键（弹窗打开时）：⌘R 刷新，⌘, 设置，⌘Q 退出。

核心库与测试可在任意平台（含 Linux）编译：

```bash
swift build --target TokenBarCore
swift test
```

## 账户：自动检测

TokenBar 每次启动以及之后每 5 分钟会自动查找本机的账户，不需要任何配置：

- 默认目录：`~/.claude`、`~/.config/claude`（及 `$XDG_CONFIG_HOME/claude`）、`~/.codex`、`~/.gemini`、`~/.local/share/muse/sessions`；
- 同级的配置目录：`~/.claude-*`、`~/.claude_*`、`~/.config/claude-*`、`~/.codex-*`、`~/.gemini-*`；
- shell 启动文件里设置的目录：读取 `~/.zshenv`、`~/.zprofile`、`~/.zshrc`、`~/.zlogin`、`~/.bash_profile`、`~/.bashrc`、`~/.profile`、`~/.config/fish/config.fish`、`~/.config/fish/conf.d/*.fish` 中的
  `CLAUDE_CONFIG_DIR`、`CODEX_HOME`、`GEMINI_CLI_HOME`、`MUSE_SESSIONS_DIR`，包括 `export`、fish 的 `set -gx`、
  以及 `alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'` 这类别名和单行函数。
  从 Finder/Dock 启动的应用继承不到终端的环境变量，所以 TokenBar 直接读这些文件（只做文本解析，不执行，不跟随 `source`；只认 `~`、`$HOME`、`${HOME}`）；
- 进程自己的环境变量（例如用 `swift run` 从终端启动时）；
- 通过 TokenBar 登录添加的账户（见下）。

只有看起来确实是该 CLI 主目录的文件夹才会被加入（有日志目录或登录文件，例如 Claude 的 `projects/`、`.credentials.json`、`.claude.json` 里的 `oauthAccount`；Codex 的 `sessions/`、`auth.json`；Gemini 的 `tmp/`、`oauth_creds.json`）。
同一个目录（符号链接、末尾斜杠）只会出现一次。在设置里删除的账户会被记住，之后不会被自动加回来（手动再添加同一目录即可恢复）。

账户名自动取自本地文件里的登录身份（不联网、不读钥匙串、不显示任何令牌）：

| 提供方 | 身份来源 |
| --- | --- |
| Claude Code | `.claude.json` 的 `oauthAccount.emailAddress`（默认账户在 `~/.claude.json`，设置了 `CLAUDE_CONFIG_DIR` 时在该目录内）；套餐取自 `.credentials.json` 的 `subscriptionType`（若存在） |
| Codex | `auth.json` 中 `id_token` 的 `email` 声明与 `chatgpt_plan_type` |
| Gemini CLI | `google_accounts.json` 的 `active` |

读不到时依次用别名名称、文件夹名（如 `claude-work`，默认目录显示为 `Default`）。手动改名后不再自动改名。

设置 → Accounts 里每个账户显示：身份（邮箱 · 套餐 · 组织）、来源（Detected / Signed in here / Added manually）、状态点、启用开关、在线额度开关，以及“⋯”菜单（复制 shell 别名、在 Finder 中显示、删除）。顶部的 **Rescan** 立即重新检测。
Muse（muse.ai）账户没有文件夹，不参与自动检测，也没有路径、Finder、shell 别名等选项，见下文。

## 登录另一个账户

Claude Code、Codex、Gemini CLI 下各有 **Sign in to another account**。TokenBar 不自己实现 OAuth，也不读浏览器 Cookie：它在 TokenBar 管理的目录
`~/Library/Application Support/TokenBar/accounts/<提供方>/<小写 uuid>` 里调用官方 CLI 自己的登录（通过 `CODEX_HOME`、`CLAUDE_CONFIG_DIR`、`GEMINI_CLI_HOME` 指向该目录），
你授权后 CLI 把凭据写进这个目录（Claude Code 在 macOS 上写进钥匙串），TokenBar 检测到后自动加入账户并显示在线额度。

| 提供方 | 登录方式 |
| --- | --- |
| Codex | 后台运行 `codex login`，直接打开浏览器；`auth.json` 写入后完成 |
| Claude Code | 后台运行 `claude auth login --claudeai`，直接打开浏览器；钥匙串项出现（只查询是否存在，不读取内容，不会弹出钥匙串密码框）或命令成功退出后完成 |
| Gemini CLI | 需要终端：会打开一个“终端”窗口运行 `gemini`，再在浏览器里登录 Google；`.gemini/oauth_creds.json` 写入后完成。个人 Google 账户可能被 Google 拒绝用于 Gemini CLI |

- 这样添加的账户能显示额度；token 数只统计**通过这个配置目录**产生的用量。可以在“⋯”菜单里复制一个 shell 别名，用它在终端里使用该账户。
- 账户路径按 CLI 拿到的字符串原样保存（不做规范化、不解析符号链接、不去掉末尾斜杠），因为 Claude Code 的钥匙串项名称由 `CLAUDE_CONFIG_DIR` 的字面值计算；重新启动后自动检测会找回同一个目录，不会出现第二个账户。Gemini 账户保存的是其中的 `.gemini` 数据目录。
- 删除这样的账户会同时删除 TokenBar 创建的这个目录（其中的登录）。启动时还会清理没有任何账户使用、且超过一小时的管理目录（异常退出留下的半成品）。退出 TokenBar 时，正在进行的登录会被取消，相应的 CLI 进程会被结束。
- CLI 未安装时会显示安装命令（可选中复制）和 **Try again**。Muse Code 不提供此功能。
- 首次使用的已知风险：如果 Claude Code 的登录一直停在等待状态，可以点 Cancel，改用 Advanced 手动添加你自己设置了 `CLAUDE_CONFIG_DIR` 的目录。

## Muse（muse.ai）

Muse 是 Meta 的私人助理（muse.ai），与编程 CLI Muse Code 是两个产品。muse.ai 只提供每周额度（已用百分比、重置时间、套餐、剩余 token、可能有的加购额度），没有本地日志，因此没有 token 数、7 天柱状图和“今日”数字，也不计入菜单栏数字；但它的每周额度超过 90% 时，菜单栏图标同样会变成警告标志。

- **添加账户**：设置 → Accounts → Muse → **Sign in to Muse**（不需要安装任何 CLI）。TokenBar 打开一个自己的窗口显示 muse.ai，你在其中正常登录；确认登录有效后窗口自动关闭并添加账户。每次登录使用一个全新的、不落盘的浏览器存储，所以多个账户互不影响。默认名称取自套餐（如 “Muse Power”，同套餐的第二个账户为 “Muse Power 2”），可以直接改名。
- **会话保存在钥匙串**：登录后只保留发往 `https://muse.ai/` 的 Cookie，序列化后存入 macOS 钥匙串（服务名 `com.tokenbar.app`，按账户 id 区分），**不会**写进 `config.json` 或日志。
- **会话过期**：显示 “Muse session expired. Sign in again”，并出现 **Sign in again** 按钮，重新登录后替换同一账户的会话。过期后不再在后台重试，直到重新登录。muse.ai 改版导致读不出数据时显示 “muse.ai changed and usage could not be read”；最近一次成功的数据会继续显示。
- **删除账户**：会同时删除钥匙串中保存的会话；你的 muse.ai 账户本身不受影响。
- **非官方**：这是对 muse.ai 网页内部接口的非官方使用，随时可能因网站改版而失效。

## 高级：手动添加目录

## 高级：手动添加目录

每个提供方下的 **Advanced** 里仍可手动填写或选择数据目录（下方会提示该目录是否有效）：

| 提供方 | 数据目录应填写 | 实际读取 |
| --- | --- | --- |
| Claude Code | 配置目录，如 `~/.claude` 或另一个 `CLAUDE_CONFIG_DIR` | `<目录>/projects/**/*.jsonl` |
| Codex | `CODEX_HOME`，如 `~/.codex` | `<目录>/sessions/**`、`<目录>/archived_sessions` |
| Gemini CLI | `~/.gemini` 或 `$GEMINI_CLI_HOME/.gemini` | `<目录>/tmp/*/chats/**/session-*.json[l]` |
| Muse Code | sessions 目录，如 `~/.local/share/muse/sessions` | `<目录>/**/session.jsonl` |

“General”里可设置登录时自动启动、刷新间隔、菜单栏显示方式、在线额度总开关。

配置保存在 `~/Library/Application Support/TokenBar/config.json`，不含任何令牌、Cookie 或密钥。旧版本的配置文件可以直接读取（新字段缺失时取默认值；旧版自动生成的账户名会改为登录邮箱）；无法识别的提供方的账户会被保留但不显示，不会导致崩溃。

## 联网说明（在线额度）

默认开启在线额度（Settings → General → Check quota online；每个账户也可用 Online quota 开关单独关闭）。开启时 TokenBar 会读取**各 CLI 已经保存的登录凭据**（Muse 为在 TokenBar 内登录保存的会话），并向以下地址发请求，**至少间隔 5 分钟**（手动刷新最短 30 秒），失败后指数退避（5 分钟起，最长 1 小时）：

| 提供方 | 凭据位置 | 请求 |
| --- | --- | --- |
| Claude Code | `<配置目录>/.credentials.json`；未设置 `CLAUDE_CONFIG_DIR` 的默认账户读钥匙串项 `Claude Code-credentials`；设置了 `CLAUDE_CONFIG_DIR` 的配置目录（包括 TokenBar 登录添加的）读 `Claude Code-credentials-<对该变量的确切字符串（NFC）做 SHA-256 的前 8 位十六进制>`（规则已从 Claude Code 程序中确认） | `GET api.anthropic.com/api/oauth/usage`；续期（仅文件中的登录）`POST platform.claude.com/v1/oauth/token` |
| Codex | `<CODEX_HOME>/auth.json` | `GET chatgpt.com/backend-api/wham/usage`（不续期） |
| Gemini CLI | `<~/.gemini>/oauth_creds.json` | `POST cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`、`:retrieveUserQuota`；续期 `POST oauth2.googleapis.com/token` |
| Muse（muse.ai） | 钥匙串中 TokenBar 保存的 muse.ai 会话 Cookie | `POST https://muse.ai/`（网页设置对话框使用的 Next.js server action `fetchSubscriptionAction`，`Next-Action` 头携带 action id）；action id 失效时（网站更新后）重新获取一次：`GET https://muse.ai/` 及其 `/_next/static/chunks/*.js`（静态文件请求不带 Cookie），找到的 id 保存在 UserDefaults（公开信息，不是密钥）。登录窗口里还会 `GET https://muse.ai/` 确认会话。只跟随同源 HTTPS 重定向，Cookie 不会被转发到其他域名 |
| Muse Code | — | 暂无（不联网，仅本地 token） |

这些接口都是各 CLI / 网站自用的非公开接口，可能随时变化。关闭在线额度后 TokenBar 不再发出这些请求（Muse 账户不会调用 muse.ai；只有你主动点 Sign in to Muse 时，登录窗口本身会访问 muse.ai），行为与纯本地模式一致。只想关闭 Muse 时，关掉对应账户的 Online quota 开关或删除该账户即可。令牌和 Cookie 不会被写入日志或显示在界面上。

### 登录过期与自动续期

- **Claude Code / Gemini CLI**：访问令牌过期（或收到 401）时，如果登录保存在**文件**里（`.credentials.json`、`oauth_creds.json`），TokenBar 会用刷新令牌续期，**重试一次**。因为刷新令牌可能轮换，续期遵循严格流程：先重新读取 CLI 的凭据（如果 CLI 已经续期就直接采用）；先确认文件可写才会续期；写回时保留所有未知字段，采用“临时文件 + 重命名”原子写入并保留权限（0600）；写入前再比对一次，CLI 抢先更新则不覆盖。Gemini 续期需要 Gemini CLI 自带的 OAuth 客户端信息，TokenBar 从已安装的 CLI 里读取（也可用环境变量 `GEMINI_OAUTH_CLIENT_ID` / `GEMINI_OAUTH_CLIENT_SECRET`）；找不到时提示 “Run gemini once to renew it”。
- **钥匙串中的 Claude 登录只读**：TokenBar 从不更新钥匙串里的 Claude Code 登录（更新别的程序创建的钥匙串项可能重置其访问控制，导致 CLI 再次索要钥匙串密码）。过期时显示 “Can't renew the sign-in safely. Run claude once to renew it”，运行一次 `claude` 让 CLI 自己续期后，下次刷新自动恢复。
- **Codex**：与 CodexBar 一致，TokenBar **不会**自己续期 Codex 的登录（CLI 独占刷新令牌）。过期时显示 “Sign-in expired. Run codex once to renew it”，CLI 续期后下次刷新自动恢复。
- 文件不可写时同样不会续期，显示 “Can't renew the sign-in safely. Run claude（或 gemini）once to renew it”。
- Claude Code 在 macOS 上通常把凭据放在钥匙串：首次读取会弹出授权窗口，请选“始终允许”（Always Allow）。选“拒绝”后不会再自动弹窗，手动点刷新才会重试。
- 网络或认证失败只会在卡片上显示一行小提示，**不会影响本地 token 数字**；最近一次成功的额度会继续显示。

## 统计口径

- 输入 = 不含缓存命中的输入；输出 = 输出（含推理 token）；缓存 = 缓存读取 + 缓存写入。
- 卡片与菜单栏的数字默认不含缓存（缓存读取通常远大于其他项），可在“通用”中改为包含。
- “今日 / 本月”按本机时区的自然日、自然月；“近 7 天”为含今天的 7 个自然日（柱状图同此）。
- Claude 按 `message.id + requestId` 去重；Codex 由累计值求差；Gemini 按会话 + 消息 id 去重；Muse 按 stream + sequence 去重。

## 已知限制

- Muse Code 为闭源软件，日志格式来自第三方工具的逆向，可能随版本变化；其额度接口的响应结构无法从公开资料确认，所以不做在线额度。
- Gemini CLI 默认把登录保存在 `oauth_creds.json`；若设置了 `GEMINI_FORCE_ENCRYPTED_FILE_STORAGE=true`，凭据改为加密存储，TokenBar 无法读取在线额度。
- 提供方名称 “Muse Code” 指 Meta 的编程 CLI；“Muse” 指 Meta 的私人助理（muse.ai）。muse.ai 的支持依赖网页内部接口与会话 Cookie，属于非官方用法，网站改版后可能失效；muse.ai 不提供账户邮箱，所以账户默认按套餐命名。登录窗口是内嵌浏览器，某些第三方登录方式（如 Google）可能拒绝内嵌浏览器。
- shell 启动文件只做简单的文本解析：需要执行才能得到的值（如 `$(...)`、其他变量）会被忽略，这类目录请用 Advanced 手动添加。
- Codex 的 fork / 恢复会话会继承父会话的累计值，极端情况下与官方统计有出入。
- 不计算费用，只统计 token。
