import AppKit
import SwiftUI

private struct SettingsRowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Inline Control-Center style configuration & 1-click Agent Gallery embedded inside the `336pt` Hover Panel.
/// Driven 100% by `ProviderCatalog` with zero per-provider switch duplication.
struct InlineSettingsView: View {
    @ObservedObject var viewModel: QuotaViewModel
    @ObservedObject private var prefs = AppPreferences.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var scan = LocalAppScanResult.scan()

    @State private var expandedKeyID: String? = nil
    @State private var draggingRowID: String? = nil
    @State private var rowFrames: [String: CGRect] = [:]

    private var cardBg: Color {
        colorScheme == .dark ? Color.white.opacity(0.065) : Color.black.opacity(0.038)
    }

    private var cardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            headerBar
            modeSegmentedTabs

            if viewModel.settingsPage == "add" {
                addCatalogBody
            } else {
                manageEnabledBody
            }
        }
        .onAppear {
            scan = LocalAppScanResult.scan()
            if let focus = viewModel.focusedProviderID {
                expandedKeyID = focus
                viewModel.onRequestKeyFocus?()
            }
        }
        .onDisappear {
            draggingRowID = nil
            viewModel.onReleaseKeyFocus?()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Button {
                viewModel.closeInlineSettings()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("返回看板")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 3)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button("完成") {
                viewModel.closeInlineSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
        .padding(.horizontal, 2)
    }

    private var modeSegmentedTabs: some View {
        HStack(spacing: 4) {
            tabPill(title: "✦ 一键添加", tag: "add")
            tabPill(title: "已启用 (\(enabledOrderedDescriptors.count))", tag: "manage")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
        )
    }

    private func tabPill(title: String, tag: String) -> some View {
        let selected = (viewModel.settingsPage == tag)
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                viewModel.settingsPage = tag
                expandedKeyID = nil
                viewModel.onReleaseKeyFocus?()
            }
            viewModel.onLayoutChange?()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(selected ? (colorScheme == .dark ? Color.white.opacity(0.14) : Color.white) : Color.clear)
                        .shadow(color: selected ? .black.opacity(0.08) : .clear, radius: 2, x: 0, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 1: Foolproof 1-Click Agent Store (`✦ 一键添加`)

    private var sortedCatalog: [ProviderDescriptor] {
        ProviderCatalog.all.sorted { a, b in
            let ia = scan.isInstalled(a.id)
            let ib = scan.isInstalled(b.id)
            if ia != ib { return ia && !ib }
            return false
        }
    }

    private var addCatalogBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("发现本机应用或点「+ 一键添加」，无需配置复杂参数")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 3)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach(sortedCatalog) { desc in
                        catalogCard(for: desc)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(height: 332)
        }
    }

    private func catalogCard(for desc: ProviderDescriptor) -> some View {
        let enabled = prefs.isProviderEnabled(desc.id)
        let installed = scan.isInstalled(desc.id)
        let ready = isReady(desc)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                BrandBadge(id: desc.id)

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 4) {
                        Text(desc.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)

                        if installed {
                            Text(desc.id == "dsh" && scan.hasDSHDesktopApp ? "桌面端已装" : "本机已装")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(red: 0.14, green: 0.76, blue: 0.50))
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Color(red: 0.14, green: 0.76, blue: 0.50).opacity(0.15))
                                )
                        }
                    }

                    Text(desc.subtitle)
                        .font(.system(size: 9.8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                catalogTrailingAction(for: desc, enabled: enabled, ready: ready)
            }

            if expandedKeyID == desc.id {
                keyEditorBar(for: desc)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(cardBg))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(enabled ? Color.accentColor.opacity(0.28) : cardStroke, lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private func catalogTrailingAction(for desc: ProviderDescriptor, enabled: Bool, ready: Bool) -> some View {
        if !enabled {
            Button {
                handleOneClickAdd(desc)
            } label: {
                Text("+ 一键添加")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
        } else if ready {
            HStack(spacing: 5) {
                if let live = item(for: desc.id), !live.isPending {
                    Text(live.remainingText)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(red: 0.16, green: 0.78, blue: 0.50))
                } else {
                    Text("✓ 已启用")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Button {
                    prefs.setProviderEnabled(desc.id, false)
                    if expandedKeyID == desc.id {
                        expandedKeyID = nil
                        viewModel.onReleaseKeyFocus?()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("从看板移除")
            }
        } else {
            HStack(spacing: 4) {
                Button {
                    triggerQuickConnect(for: desc)
                } label: {
                    Text(quickConnectLabel(for: desc))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)

                Button {
                    prefs.setProviderEnabled(desc.id, false)
                    if expandedKeyID == desc.id {
                        expandedKeyID = nil
                        viewModel.onReleaseKeyFocus?()
                    }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("取消添加")
            }
        }
    }

    private func quickConnectLabel(for desc: ProviderDescriptor) -> String {
        switch desc.authStyle {
        case .webLogin, .hybridDSH:
            return "立即登录"
        case .desktopKeychain:
            return scan.isInstalled(desc.id) ? "一键授权" : "未装客户端"
        case .hybridCopilot:
            return scan.hasGHCLI ? "一键连接" : "填入 Token"
        case .apiKey:
            return expandedKeyID == desc.id ? "收起" : "填入 Key"
        }
    }

    private func handleOneClickAdd(_ desc: ProviderDescriptor) {
        prefs.setProviderEnabled(desc.id, true)
        if desc.needsManualKeyOnAdd,
           let secretKey = desc.primarySecretKey,
           prefs.credential(for: secretKey).isEmpty
        {
            withAnimation(.easeInOut(duration: 0.18)) {
                expandedKeyID = desc.id
            }
        } else if desc.id == "copilot" && !scan.hasCopilotToken && scan.hasGHCLI {
            viewModel.connectCopilotViaGHCLI()
        }
    }

    private func triggerQuickConnect(for desc: ProviderDescriptor) {
        if let webProvider = desc.webLoginProvider {
            WebLoginController.shared.presentLogin(for: webProvider) { fresh in
                viewModel.applyInteractiveLoginResult(fresh)
            }
            return
        }
        switch desc.authStyle {
        case .desktopKeychain:
            if scan.isInstalled(desc.id) {
                viewModel.authorizeDesktopKeychain(preferredID: desc.id)
            }
        case .hybridCopilot:
            if scan.hasGHCLI && prefs.credential(for: desc.primarySecretKey).isEmpty {
                viewModel.connectCopilotViaGHCLI()
            } else {
                toggleKeyEditor(for: desc.id)
            }
        case .apiKey:
            toggleKeyEditor(for: desc.id)
        default:
            break
        }
    }

    private func toggleKeyEditor(for id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedKeyID = (expandedKeyID == id) ? nil : id
            if expandedKeyID == nil { viewModel.onReleaseKeyFocus?() }
        }
        viewModel.onLayoutChange?()
    }

    // MARK: - Tab 2: Manage & Reorder Enabled Services (`已启用`)

    private var enabledOrderedDescriptors: [ProviderDescriptor] {
        prefs.normalizedProviderOrder.compactMap { id in
            guard prefs.isProviderEnabled(id) else { return nil }
            return ProviderCatalog.byID[id]
        }
    }

    private var manageEnabledBody: some View {
        VStack(spacing: 8) {
            if enabledOrderedDescriptors.isEmpty {
                VStack(spacing: 8) {
                    Text("当前没有启用任何 Agent")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("✦ 去一键添加主流 Agent") {
                        viewModel.settingsPage = "add"
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
            } else {
                let ordered = enabledOrderedDescriptors
                let listHeight = min(CGFloat(ordered.count) * 35.0 + (expandedKeyID != nil ? 42.0 : 8.0), 270.0)
                ScrollView(.vertical, showsIndicators: ordered.count > 7) {
                    VStack(spacing: 0) {
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { idx, desc in
                            manageRow(for: desc)
                                .opacity(draggingRowID == desc.id ? 0.35 : 1.0)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: SettingsRowFrameKey.self,
                                            value: [desc.id: geo.frame(in: .named("settingsRows"))]
                                        )
                                    }
                                )
                            if idx < ordered.count - 1 {
                                Divider().opacity(0.45)
                            }
                        }
                    }
                    .coordinateSpace(name: "settingsRows")
                    .onPreferenceChange(SettingsRowFrameKey.self) { rowFrames = $0 }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .frame(height: listHeight)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(cardStroke, lineWidth: 0.8))
            }

            globalPreferencesCard

            HStack {
                Text("拖拽 ≡ 或主面板卡片可排序 · ⌘拖顶栏改位置")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button("退出应用") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.red.opacity(0.85))
            }
            .padding(.horizontal, 4)
            .padding(.top, 1)
        }
    }

    private var globalPreferencesCard: some View {
        VStack(spacing: 6) {
            HStack {
                Text("状态栏显示最紧缺余量%")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Toggle("", isOn: $prefs.showPercentInMenuBar)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            HStack {
                Text("自动刷新周期")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Picker("", selection: $prefs.refreshIntervalSeconds) {
                    Text("1分").tag(60)
                    Text("2分").tag(120)
                    Text("5分").tag(300)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 118)
            }

            HStack {
                Text("登录系统自动启动")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Toggle("", isOn: $prefs.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(cardStroke, lineWidth: 0.8))
    }

    private func manageRow(for desc: ProviderDescriptor) -> some View {
        let ready = isReady(desc)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 28)
                    .contentShape(Rectangle())
                    .gesture(rowDragGesture(for: desc.id))
                    .help("按住上下拖动排序")

                BrandBadge(id: desc.id)
                    .scaleEffect(0.90)

                Text(desc.shortName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                miniStatusPill(item: item(for: desc.id))

                Spacer(minLength: 4)

                if let actTitle = manageActionTitle(for: desc, ready: ready) {
                    Button(actTitle) {
                        handleManageAction(for: desc, ready: ready)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                Toggle("", isOn: Binding(
                    get: { prefs.isProviderEnabled(desc.id) },
                    set: { val in
                        prefs.setProviderEnabled(desc.id, val)
                        if !val && expandedKeyID == desc.id {
                            expandedKeyID = nil
                            viewModel.onReleaseKeyFocus?()
                        }
                        viewModel.onLayoutChange?()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .frame(height: 31)

            if expandedKeyID == desc.id {
                keyEditorBar(for: desc)
                    .padding(.bottom, 5)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Inline Key Editor & Helpers

    private func keyEditorBar(for desc: ProviderDescriptor) -> some View {
        let secretKey = desc.primarySecretKey ?? desc.id
        let binding = Binding<String>(
            get: { prefs.credential(for: secretKey) },
            set: { prefs.setCredential($0, for: secretKey) }
        )

        return HStack(spacing: 5) {
            TextField(desc.keyPlaceholder ?? "粘贴 API Key", text: binding)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 10.5, design: .monospaced))
                .simultaneousGesture(TapGesture().onEnded {
                    viewModel.onRequestKeyFocus?()
                })

            Button("粘贴") {
                if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !clip.isEmpty
                {
                    prefs.setCredential(clip, for: secretKey, immediate: true)
                    expandedKeyID = nil
                    viewModel.onReleaseKeyFocus?()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("零焦点直接读取剪贴板，完全不触碰输入法")

            if let portal = desc.keyPortalURL, let url = URL(string: portal) {
                Button("获取") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Button("保存") {
                expandedKeyID = nil
                viewModel.onReleaseKeyFocus?()
                Task { await viewModel.refresh(force: true) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
        }
    }

    private func rowDragGesture(for sourceID: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("settingsRows"))
            .onChanged { value in
                if draggingRowID == nil { draggingRowID = sourceID }
                let y = value.location.y
                for candidate in enabledOrderedDescriptors where candidate.id != sourceID {
                    guard let rect = rowFrames[candidate.id] else { continue }
                    if y >= rect.minY && y <= rect.maxY {
                        viewModel.moveItem(fromID: sourceID, toID: candidate.id)
                        break
                    }
                }
            }
            .onEnded { _ in
                draggingRowID = nil
            }
    }

    private func item(for id: String) -> QuotaItem? {
        viewModel.items.first(where: { $0.id == id })
    }

    private func isReady(_ desc: ProviderDescriptor) -> Bool {
        if let live = item(for: desc.id), !live.isPending { return true }
        let primaryVal = prefs.credential(for: desc.primarySecretKey)
        let secondaryVal = prefs.credential(for: desc.secondarySecretKey)

        switch desc.id {
        case "chatgpt":  return scan.hasCodexAuth || !primaryVal.isEmpty
        case "claude":   return scan.hasClaudeCodeCreds || !primaryVal.isEmpty
        case "copilot":  return scan.hasCopilotToken || !primaryVal.isEmpty
        case "dsh":      return scan.isInstalled("dsh") || !primaryVal.isEmpty || !secondaryVal.isEmpty
        case "qoder", "qwenwork":
            return false
        default:
            return !primaryVal.isEmpty
        }
    }

    private func manageActionTitle(for desc: ProviderDescriptor, ready: Bool) -> String? {
        switch desc.authStyle {
        case .webLogin:
            return ready ? "换号" : "登录"
        case .hybridDSH:
            return ready ? "Key" : "登录"
        case .desktopKeychain:
            if ready { return nil }
            return scan.isInstalled(desc.id) ? "授权" : nil
        case .hybridCopilot:
            if ready { return "Token" }
            return scan.hasGHCLI ? "连接" : "Token"
        case .apiKey:
            return expandedKeyID == desc.id ? "收起" : "Key"
        }
    }

    private func handleManageAction(for desc: ProviderDescriptor, ready: Bool) {
        switch desc.authStyle {
        case .webLogin(let webProvider):
            WebLoginController.shared.presentLogin(for: webProvider) { fresh in
                viewModel.applyInteractiveLoginResult(fresh)
            }
        case .hybridDSH:
            if ready {
                toggleKeyEditor(for: desc.id)
            } else {
                WebLoginController.shared.presentLogin(for: .deepseek) { fresh in
                    viewModel.applyInteractiveLoginResult(fresh)
                }
            }
        case .desktopKeychain:
            viewModel.authorizeDesktopKeychain(preferredID: desc.id)
        case .hybridCopilot:
            if !ready && scan.hasGHCLI && prefs.credential(for: desc.primarySecretKey).isEmpty {
                viewModel.connectCopilotViaGHCLI()
            } else {
                toggleKeyEditor(for: desc.id)
            }
        case .apiKey:
            toggleKeyEditor(for: desc.id)
        }
    }

    @ViewBuilder
    private func miniStatusPill(item: QuotaItem?) -> some View {
        if let item, !item.isPending {
            Text(item.remainingText)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.14, green: 0.76, blue: 0.50))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color(red: 0.14, green: 0.76, blue: 0.50).opacity(0.14)))
        } else {
            Text(item?.windowLabel == "待授权" ? "待授权" : "待配置")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
    }
}
