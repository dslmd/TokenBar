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
        .frame(width: 560, height: 480)
        .padding()
    }
}

// MARK: - Accounts

struct AccountsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(model.registry.providers, id: \.id) { provider in
                    VStack(alignment: .leading, spacing: 6) {
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
                    Divider()
                }
            }
            .padding(4)
        }
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    let provider: any UsageProvider

    @State private var name: String = ""
    @State private var path: String = ""
    @State private var apiKey: String = ""
    @State private var hasKey = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("名称", text: $name)
                    .frame(width: 130)
                    .onSubmit { model.rename(account.id, to: name) }
                    .onChange(of: name) { model.rename(account.id, to: $0) }
                TextField("数据目录", text: $path)
                    .onSubmit { model.setDataPath(account.id, to: path) }
                Button("选择…") { choose() }
                Button(role: .destructive) {
                    model.removeAccount(account.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("删除此账户（不会删除任何日志文件）")
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
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = account.name
            path = account.dataPath
            hasKey = model.secrets.secret(for: account.id) != nil
        }
        .onDisappear { model.setDataPath(account.id, to: path) }
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
            model.setDataPath(account.id, to: path)
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
                Toggle("包含缓存 token", isOn: Binding(
                    get: { model.settings.menuBarIncludesCache },
                    set: { v in model.updateSettings { $0.menuBarIncludesCache = v } }))
                Text("当前显示：\(model.menuBarTitle)").foregroundStyle(.secondary)
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
