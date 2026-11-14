import SwiftUI
import AppKit
import TokenBarCore

/// Hosts SettingsView in a plain NSWindow. This avoids the `Settings` scene, which is
/// unreliable to open from an accessory (no Dock icon) app on macOS 13/14.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(model)
                    .environment(\.locale, Locale(identifier: "zh_CN")))
            let w = NSWindow(contentViewController: host)
            w.title = "TokenBar 设置"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsTab().tabItem { Label("账户", systemImage: "person.2") }
            GeneralTab().tabItem { Label("通用", systemImage: "gearshape") }
        }
        .frame(width: 600, height: 540)
        .padding()
    }
}

// MARK: - Accounts

struct AccountsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(model.registry.providers, id: \.id) { provider in
                    ProviderAccounts(provider: provider)
                    Divider()
                }
            }
            .padding(6)
        }
    }
}

struct ProviderAccounts: View {
    @EnvironmentObject var model: AppModel
    let provider: any UsageProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(provider.displayName, systemImage: provider.symbolName)
                .font(.headline)
            Text(provider.dataPathHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.accounts(for: provider.id)) { account in
                AccountRow(account: account, provider: provider)
            }
            Button {
                model.addAccount(providerID: provider.id)
            } label: {
                Label("添加 \(provider.displayName) 账户", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }
}

@MainActor
struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    let provider: any UsageProvider

    @State private var path = ""
    @State private var validation: PathValidation = .missing
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var loaded = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("名称", text: Binding(
                    get: { account.name },
                    set: { model.rename(account.id, to: $0) }))
                    .frame(width: 150)
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除此账户（不会删除任何日志文件）")
                .accessibilityLabel("删除账户")
            }
            HStack {
                TextField("数据目录", text: $path)
                    .onSubmit { commitPath() }
                Button("选择…") { choose() }
            }
            HStack(spacing: 4) {
                Image(systemName: validation.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(validation.isValid ? Color.green : Color.orange)
                Text(validation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.backendSupportsOnlineQuota(provider.id) {
                Toggle("使用在线额度", isOn: Binding(
                    get: { account.onlineQuotaEnabled },
                    set: { model.setOnlineQuota(account.id, enabled: $0) }))
                    .font(.caption)
            }
            if provider.supportsAPIKey {
                HStack {
                    SecureField(hasKey ? "API Key 已保存到钥匙串" : "API Key（可选，保存到钥匙串）", text: $apiKey)
                        .onSubmit { saveKey() }
                    Button("保存") { saveKey() }
                    if hasKey {
                        Button("清除") {
                            try? model.secrets.setSecret(nil, for: account.id)
                            hasKey = false
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .onAppear {
            guard !loaded else { return }
            loaded = true
            path = account.dataPath
            validation = provider.validate(dataPath: path)
            hasKey = model.secrets.secret(for: account.id) != nil
        }
        .onDisappear { commitPath() }
        .confirmationDialog("删除账户“\(account.name)”？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { model.removeAccount(account.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会移除 TokenBar 中的配置，不会删除任何日志文件。")
        }
    }

    private func commitPath() {
        guard loaded else { return }
        validation = provider.validate(dataPath: path)
        model.setDataPath(account.id, to: path)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            commitPath()
        }
    }

    private func saveKey() {
        guard !apiKey.isEmpty else { return }
        try? model.secrets.setSecret(apiKey, for: account.id)
        apiKey = ""
        hasKey = true
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                if model.launchAtLoginNeedsApproval {
                    Text("请在“系统设置 → 通用 → 登录项”中允许 TokenBar。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("刷新") {
                Picker("自动刷新间隔", selection: Binding(
                    get: { model.settings.refreshIntervalSeconds },
                    set: { v in model.updateSettings { $0.refreshIntervalSeconds = v } })) {
                    Text("15 秒").tag(15)
                    Text("30 秒").tag(30)
                    Text("1 分钟").tag(60)
                    Text("2 分钟").tag(120)
                    Text("5 分钟").tag(300)
                }
            }
            Section("菜单栏") {
                Picker("显示范围", selection: Binding(
                    get: { model.settings.menuBarProviderID ?? "" },
                    set: { v in model.updateSettings { $0.menuBarProviderID = v.isEmpty ? nil : v } })) {
                    Text("全部").tag("")
                    ForEach(model.registry.providers, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                Picker("统计周期", selection: Binding(
                    get: { model.settings.menuBarPeriod },
                    set: { v in model.updateSettings { $0.menuBarPeriod = v } })) {
                    ForEach(MenuBarPeriod.allCases, id: \.self) { Text(Fmt.periodTitle($0)).tag($0) }
                }
                Toggle("在图标旁显示数字", isOn: Binding(
                    get: { model.settings.menuBarShowsNumber },
                    set: { v in model.updateSettings { $0.menuBarShowsNumber = v } }))
                Toggle("数字包含缓存 token", isOn: Binding(
                    get: { model.settings.menuBarIncludesCache },
                    set: { v in model.updateSettings { $0.menuBarIncludesCache = v } }))
                Text("当前显示：\(model.menuBarTitle)。任一额度超过 90% 时图标会变为警告标志。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("在线额度") {
                Toggle("启用在线额度", isOn: Binding(
                    get: { model.settings.onlineQuotaEnabled },
                    set: { v in model.updateSettings { $0.onlineQuotaEnabled = v } }))
                Text("开启后，TokenBar 会读取各 CLI 已保存的登录凭据，并至少间隔 5 分钟向 OpenAI、Anthropic、Google 的额度接口发起请求。关闭后完全不联网，只统计本地日志。每个账户也可单独关闭。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("账户") {
                Button("重新检测默认账户") { model.redetectDefaults() }
                Text("只会添加尚未配置的默认目录（~/.claude、~/.codex、~/.gemini 等）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
