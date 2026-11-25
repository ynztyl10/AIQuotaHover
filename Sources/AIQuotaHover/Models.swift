import AppKit
import Carbon
import Combine
import Darwin
import Foundation
import QuotaAdapters
import SwiftUI

/// Vendor-neutral macOS Input Method (IME) guard powered by official Carbon `TextInputSources` metadata.
/// Works generically for ALL macOS Input Methods — Apple Pinyin/Shuangpin/Wubi, Sogou, WeChat Input,
/// Rime Squirrel, Baidu, iFlytek, Zhuyin, Cangjie, Japanese, Korean, etc. — without any brand hardcoding.
@MainActor
enum InputMethodGuard {
    private static var workItem1: DispatchWorkItem?
    private static var workItem2: DispatchWorkItem?

    /// Returns the user's live active Input Method source ID if and only if the current keyboard input source
    /// is a genuine Input Method (`kTISTypeKeyboardInputMode` or `kTISTypeKeyboardInputMethodWithoutModes`)
    /// rather than a plain keyboard layout (`kTISTypeKeyboardLayout`, such as `ABC` / `U.S.`) or Roman sub-mode.
    static func currentActiveIMESourceID() -> String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard isNonRomanInputMethod(current),
              let idPtr = TISGetInputSourceProperty(current, kTISPropertyInputSourceID)
        else {
            return nil
        }
        let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        return sourceID.isEmpty ? nil : sourceID
    }

    private static func isNonRomanInputMethod(_ source: TISInputSource) -> Bool {
        guard let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
            return false
        }
        let sourceType = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
        let isIME = (sourceType == (kTISTypeKeyboardInputMode as String))
            || (sourceType == (kTISTypeKeyboardInputMethodWithoutModes as String))
        guard isIME else { return false }

        if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sid = (Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String).lowercased()
            if sid.contains(".roman") || sid.contains(".ascii") || sid.contains("keylayout.") {
                return false
            }
        }
        return true
    }

    private static func restoreIfFlippedToLayout(_ imeSourceID: String, expectedFrontmostPID: pid_t?) {
        guard !imeSourceID.isEmpty else { return }
        if let expectedPID = expectedFrontmostPID,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != expectedPID
        {
            return
        }
        // Only intervene if a system modal (`SecurityAgent` / `SecureEventInput`) flipped away from the user's IME
        guard currentActiveIMESourceID() == nil else { return }

        let filter = [kTISPropertyInputSourceID as String: imeSourceID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let target = list.first,
              isNonRomanInputMethod(target)
        else { return }
        TISSelectInputSource(target)
    }

    /// Used EXCLUSIVELY after system modal password/login sheets (`SecurityAgent` Keychain / `WKWebView` login)
    /// that activate `SecureEventInput` and force a Roman keyboard layout.
    static func restoreIMEAfterModal(savedIMESourceID: String?, expectedFrontmostPID: pid_t? = nil) {
        guard let savedIMESourceID, !savedIMESourceID.isEmpty else { return }
        workItem1?.cancel()
        workItem2?.cancel()

        let w1 = DispatchWorkItem { restoreIfFlippedToLayout(savedIMESourceID, expectedFrontmostPID: expectedFrontmostPID) }
        let w2 = DispatchWorkItem { restoreIfFlippedToLayout(savedIMESourceID, expectedFrontmostPID: expectedFrontmostPID) }
        workItem1 = w1
        workItem2 = w2
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: w1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w2)
    }
}

struct QuotaItem: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let kind: String          // "quota" | "balance"
    let windowLabel: String?
    let remainingPercent: Double
    let remainingText: String
    let subText: String?
    let resetsAt: Date?
    let status: String        // "ok" | "warning" | "critical" | "pending"
    var isStale: Bool = false
    var actionKind: String? = nil

    var isPending: Bool {
        status == "pending" || !remainingPercent.isFinite || remainingPercent < 0
    }

    var actionButtonTitle: String? {
        switch actionKind {
        case "login_gemini", "login_claude", "login_chatgpt", "login_cursor", "login_deepseek", "login_workbuddy":
            return "立即登录"
        case "connect_copilot":
            return "一键连接"
        case "auth_desktop":
            return "一键授权"
        case "open_app":
            return "打开登录"
        case "open_settings":
            return "填入 Key"
        case "retry":
            return "立即重试"
        default:
            return nil
        }
    }

    var actionSymbolName: String {
        switch actionKind {
        case "login_gemini", "login_claude", "login_chatgpt", "login_cursor", "login_deepseek", "login_workbuddy":
            return "person.badge.key.fill"
        case "connect_copilot":
            return "bolt.horizontal.circle.fill"
        case "auth_desktop":
            return "lock.open.fill"
        case "open_app":
            return "arrow.up.forward.app.fill"
        case "open_settings":
            return "key.fill"
        case "retry":
            return "arrow.clockwise"
        default:
            return "gearshape.fill"
        }
    }

    var clampedFraction: Double {
        guard !isPending else { return 0 }
        return min(1.0, max(0.0, remainingPercent / 100.0))
    }

    var accentColor: Color {
        if isPending { return Color.secondary.opacity(0.45) }
        switch status {
        case "critical": return Color(red: 1.00, green: 0.27, blue: 0.27)
        case "warning":  return Color(red: 1.00, green: 0.64, blue: 0.12)
        default:         return Color(red: 0.16, green: 0.80, blue: 0.52)
        }
    }

    func countdownString(from now: Date) -> String {
        if isStale { return "网络波动 · 显示上次缓存" }
        if kind == "balance" { return subText ?? "长期有效" }
        guard let target = resetsAt else {
            return isPending ? (subText ?? "待连接账号") : "周期自动刷新"
        }
        let diff = Int(target.timeIntervalSince(now))
        if diff <= 0 { return "即将刷新" }
        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        let mins = (diff % 3600) / 60
        if days > 0 {
            return hours > 0 ? "\(days)天\(hours)小时后刷新" : "\(days)天后刷新"
        } else if hours > 0 {
            return "\(hours)小时\(String(format: "%02d", mins))分后刷新"
        } else {
            return "\(max(1, mins))分钟后刷新"
        }
    }
}

private struct PersistedSnapshotCache: Codable {
    let updatedAt: Date
    let items: [QuotaItem]
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private var suppressChangeNotification = false
    private var debounceWork: DispatchWorkItem?

    @Published private(set) var enabledIDs: Set<String>
    @Published private(set) var credentials: [String: String]

    @Published var showPercentInMenuBar: Bool {
        didSet {
            UserDefaults.standard.set(showPercentInMenuBar, forKey: "pref.menubar.showPercent")
            scheduleNotify(immediate: true)
        }
    }
    @Published var refreshIntervalSeconds: Int {
        didSet {
            UserDefaults.standard.set(refreshIntervalSeconds, forKey: "pref.refreshInterval")
            scheduleNotify(immediate: true)
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "pref.launchAtLogin")
            Self.updateLaunchAgent(enabled: launchAtLogin)
        }
    }
    @Published var providerOrder: [String] {
        didSet {
            UserDefaults.standard.set(providerOrder, forKey: "pref.provider.order")
            onOrderChange?()
        }
    }

    var onChange: (() -> Void)?
    var onOrderChange: (() -> Void)?

    static var appConfigDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ai-quota-hover")
    }

    private static var secretsFileURL: URL {
        appConfigDir.appendingPathComponent("secrets.json")
    }

    static var snapshotCacheURL: URL {
        appConfigDir.appendingPathComponent("snapshot-cache.json")
    }

    private init() {
        let d = UserDefaults.standard
        let loadedSecrets = (try? Data(contentsOf: Self.secretsFileURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            ?? [:]
        self.credentials = loadedSecrets

        let scan = LocalAppScanResult.scan()
        let hasExistingPrefs = ProviderCatalog.all.contains { d.object(forKey: "pref.show.\($0.id)") != nil }

        var initialEnabled = Set<String>()
        for desc in ProviderCatalog.all {
            let legacyKey = "pref.show.\(desc.id)"
            if let explicit = d.object(forKey: legacyKey) as? Bool {
                if explicit { initialEnabled.insert(desc.id) }
                continue
            }
            // First-run smart auto-enable based on existing credentials or local installation
            let hasPrimary = desc.primarySecretKey.map { !(loadedSecrets[$0] ?? "").isEmpty } ?? false
            let hasSecondary = desc.secondarySecretKey.map { !(loadedSecrets[$0] ?? "").isEmpty } ?? false
            if hasPrimary || hasSecondary {
                initialEnabled.insert(desc.id)
                continue
            }
            switch desc.id {
            case "chatgpt":
                if scan.hasCodexAuth || (!hasExistingPrefs && scan.installedIDs.isEmpty) {
                    initialEnabled.insert(desc.id)
                }
            case "claude":
                if scan.hasClaudeCodeCreds { initialEnabled.insert(desc.id) }
            case "copilot":
                if !hasExistingPrefs && scan.hasCopilotToken { initialEnabled.insert(desc.id) }
            case "qoder", "qwenwork", "dsh":
                if scan.isInstalled(desc.id) { initialEnabled.insert(desc.id) }
            default:
                break
            }
        }
        self.enabledIDs = initialEnabled

        self.showPercentInMenuBar = d.object(forKey: "pref.menubar.showPercent") as? Bool ?? true
        let savedInterval = d.integer(forKey: "pref.refreshInterval")
        self.refreshIntervalSeconds = savedInterval >= 30 ? savedInterval : 120
        self.launchAtLogin = d.object(forKey: "pref.launchAtLogin") as? Bool ?? true
        self.providerOrder = (d.array(forKey: "pref.provider.order") as? [String]) ?? ProviderCatalog.defaultOrder
    }

    func isProviderEnabled(_ id: String) -> Bool {
        enabledIDs.contains(id)
    }

    func setProviderEnabled(_ id: String, _ enabled: Bool) {
        guard ProviderCatalog.byID[id] != nil else { return }
        if enabled {
            enabledIDs.insert(id)
        } else {
            enabledIDs.remove(id)
        }
        UserDefaults.standard.set(enabled, forKey: "pref.show.\(id)")
        scheduleNotify(immediate: true)
    }

    func credential(for key: String?) -> String {
        guard let key else { return "" }
        return credentials[key] ?? ""
    }

    func setCredential(_ value: String, for key: String, immediate: Bool = false) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if credentials[key] == trimmed { return }
        credentials[key] = trimmed
        persistSecrets()
        scheduleNotify(immediate: immediate)
    }

    func updateRotatedCookieSilently(secretKey: String, newHeader: String) {
        let trimmed = newHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, credentials[secretKey] != trimmed else { return }
        suppressChangeNotification = true
        defer { suppressChangeNotification = false }
        credentials[secretKey] = trimmed
        persistSecrets()
    }

    var normalizedProviderOrder: [String] {
        let validIDs = ProviderCatalog.defaultOrder
        let validSet = Set(validIDs)
        var seen = Set<String>()
        var result: [String] = []
        for id in providerOrder where validSet.contains(id) && seen.insert(id).inserted {
            result.append(id)
        }
        for id in validIDs where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    func moveProvider(fromID: String, toID: String) {
        guard fromID != toID else { return }
        var order = normalizedProviderOrder
        guard let fromIdx = order.firstIndex(of: fromID),
              let toIdx = order.firstIndex(of: toID)
        else { return }
        let moved = order.remove(at: fromIdx)
        order.insert(moved, at: toIdx)
        providerOrder = order
    }

    private func scheduleNotify(immediate: Bool) {
        guard !suppressChangeNotification else { return }
        debounceWork?.cancel()
        if immediate {
            onChange?()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persistSecrets() {
        let dir = Self.appConfigDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: credentials, options: [.sortedKeys]) {
            try? data.write(to: Self.secretsFileURL, options: [.atomic])
            chmod(Self.secretsFileURL.path, 0o600)
        }
    }

    nonisolated static func normalizedCookieHeader(from input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        let isCurlCommand = s.lowercased().hasPrefix("curl ") || s.contains(" -H ") || s.contains(" -b ") || s.contains(" --cookie ")
        if isCurlCommand {
            let patterns = [
                #"(?i)-H\s+\$?['"]cookie:\s*([^'"]+)['"]"#,
                #"(?i)(?:^|\s)(?:-b|--cookie)\s+\$?['"]([^'"]+)['"]"#
            ]
            for pat in patterns {
                if let regex = try? NSRegularExpression(pattern: pat),
                   let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                   match.numberOfRanges >= 2,
                   let valRange = Range(match.range(at: 1), in: s)
                {
                    let cleaned = sanitizeHeaderValue(String(s[valRange]))
                    if cleaned.contains("=") { return cleaned }
                }
            }
            return nil
        }

        var raw = s
        if raw.lowercased().hasPrefix("cookie:") {
            raw = String(raw.dropFirst(7))
        }
        let cleaned = sanitizeHeaderValue(raw)
        return cleaned.contains("=") ? cleaned : nil
    }

    nonisolated private static func sanitizeHeaderValue(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func updateLaunchAgent(enabled: Bool) {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.local.ai-quota-hover.plist")
        if enabled {
            let dir = plist.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let execPath = Bundle.main.executablePath ?? "/Applications/AIQuotaHover.app/Contents/MacOS/AIQuotaHover"
            let content = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key>
              <string>com.local.ai-quota-hover</string>
              <key>ProgramArguments</key>
              <array>
                <string>\(execPath)</string>
              </array>
              <key>RunAtLoad</key>
              <true/>
            </dict>
            </plist>
            """
            try? content.data(using: .utf8)?.write(to: plist, options: [.atomic])
        } else {
            try? FileManager.default.removeItem(at: plist)
        }
    }
}

private actor PendingDesktopAuthGate {
    static let shared = PendingDesktopAuthGate()
    private var blockedIDs: Set<String> = []

    func isBlocked(_ id: String) -> Bool { blockedIDs.contains(id) }
    func markBlocked(_ id: String) { blockedIDs.insert(id) }
    func clear(_ id: String) { blockedIDs.remove(id) }
}

enum HoverDataFetcher {
    static func parseDate(_ any: Any?) -> Date? {
        if let num = doubleVal(any) {
            if num > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: num / 1000.0)
            } else if num > 1_000_000_000 {
                return Date(timeIntervalSince1970: num)
            }
        }
        guard let s = any as? String, !s.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    static func doubleVal(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let s = any as? String, let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), v.isFinite {
            return v
        }
        return nil
    }

    static func safeInt(_ any: Any?) -> Int? {
        guard let v = doubleVal(any),
              v.isFinite,
              v >= -1_000_000_000_000,
              v <= 1_000_000_000_000
        else { return nil }
        return Int(v.rounded())
    }

    static func statusFor(_ rem: Double) -> String {
        if rem <= 12 { return "critical" }
        if rem <= 30 { return "warning" }
        return "ok"
    }

    static func windowTag(minutes: Int?) -> String {
        guard let m = minutes, m > 0 else { return "周期" }
        if m <= 360 { return "\(max(1, m / 60))h" }
        if m <= 1500 { return "日" }
        if m <= 11000 { return "周" }
        return "月"
    }

    static func formatInt(_ v: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.maximumFractionDigits = 0
        return fmt.string(from: NSNumber(value: v.rounded())) ?? String(format: "%.0f", v)
    }

    private static func mapBridgeError(_ error: Error) -> FetchOutcome {
        if let be = error as? BridgeError {
            switch be {
            case .needsAuthorization(let m): return .needsKeychainAuth(m)
            case .notConfigured(let m):      return .unconfigured(m)
            case .unauthorized(let m):       return .authExpired(m)
            case .network(let m), .parse(let m): return .transientFailure(m)
            }
        }
        return .transientFailure("本地读取异常")
    }

    private static func toQuotaItem(_ snap: DesktopQuotaSnapshot, id: String, name: String, windowLabel: String?) -> QuotaItem {
        QuotaItem(
            id: id,
            name: name,
            kind: snap.isBalance ? "balance" : "quota",
            windowLabel: snap.isBalance ? nil : windowLabel,
            remainingPercent: snap.remainingPercent,
            remainingText: snap.remainingText,
            subText: snap.subText,
            resetsAt: snap.resetsAt,
            status: snap.status,
            isStale: false
        )
    }

    static func fetchQoder() async -> FetchOutcome {
        if await PendingDesktopAuthGate.shared.isBlocked("qoder") {
            return .needsKeychainAuth("本机已就绪 · 授权一次即可")
        }
        do {
            let snap = try await QoderAdapter.fetchSnapshot()
            return .success(toQuotaItem(snap, id: "qoder", name: "Qoder", windowLabel: "积分"))
        } catch {
            let mapped = mapBridgeError(error)
            if case .needsKeychainAuth = mapped {
                await PendingDesktopAuthGate.shared.markBlocked("qoder")
            }
            return mapped
        }
    }

    static func fetchQwenWork() async -> FetchOutcome {
        if await PendingDesktopAuthGate.shared.isBlocked("qwenwork") {
            return .needsKeychainAuth("本机已就绪 · 授权一次即可")
        }
        do {
            let snap = try await QwenWorkAdapter.fetchSnapshot()
            return .success(toQuotaItem(snap, id: "qwenwork", name: "千问Work", windowLabel: "积分"))
        } catch {
            let mapped = mapBridgeError(error)
            if case .needsKeychainAuth = mapped {
                await PendingDesktopAuthGate.shared.markBlocked("qwenwork")
            }
            return mapped
        }
    }

    static func fetchDSH(webTokenFallback: String = "") async -> FetchOutcome {
        do {
            let snap = try await DSHAdapter.fetchSnapshot()
            return .success(toQuotaItem(snap, id: "dsh", name: "DSH", windowLabel: nil))
        } catch {
            if !webTokenFallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return await PublicBalanceProviders.fetchDeepSeekWebBalance(userToken: webTokenFallback)
            }
            return mapBridgeError(error)
        }
    }

    static func clearDesktopGate(_ id: String) async {
        await PendingDesktopAuthGate.shared.clear(id)
    }
}

@MainActor
final class QuotaViewModel: ObservableObject {
    @Published var items: [QuotaItem] = []
    @Published var lastUpdated: Date? = nil
    @Published var isRefreshing: Bool = false
    @Published var isPinned: Bool = false
    @Published var isShowingSettings: Bool = false
    @Published var settingsPage: String = "add" // "add" | "manage"
    @Published var focusedProviderID: String? = nil
    @Published var isPerformingModalAction: Bool = false
    @Published var holdPanelUntil: Date = .distantPast
    @Published var now: Date = Date()

    var onStatusChange: ((QuotaItem?) -> Void)?
    var onLayoutChange: (() -> Void)?
    var onRequestKeyFocus: (() -> Void)?
    var onReleaseKeyFocus: (() -> Void)?
    var onEnsurePanelVisible: (() -> Void)?
    var onExitInlineSettings: (() -> Void)?

    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var wakeObservers: [NSObjectProtocol] = []
    private var isSystemSleeping = false
    private var needsFollowUpRefresh = false
    private var lastRefreshAttemptAt: Date = .distantPast
    private let prefs = AppPreferences.shared

    init() {
        if let cached = Self.loadDiskCache() {
            self.items = Self.mergeCachedWithPlaceholders(cached: cached.items, prefs: prefs)
            self.lastUpdated = cached.updatedAt
        } else {
            self.items = Self.buildPlaceholders(prefs: prefs)
        }

        prefs.onChange = { [weak self] in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.restartRefreshTimer()
                await strongSelf.refresh(force: true)
                strongSelf.onLayoutChange?()
            }
        }
        prefs.onOrderChange = { [weak self] in
            self?.reorderItemsInPlace()
        }

        setupSleepWakeLifecycle()
        restartRefreshTimer()

        Task { @MainActor in
            await refresh(force: true)
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        clockTimer?.invalidate()
        clockTimer = nil
        let nc = NSWorkspace.shared.notificationCenter
        for obs in wakeObservers {
            nc.removeObserver(obs)
        }
        wakeObservers.removeAll()
    }

    func openInlineSettings() {
        settingsPage = "add"
        focusedProviderID = nil
        withAnimation(.easeInOut(duration: 0.16)) { isShowingSettings = true }
        onLayoutChange?()
    }

    func openAddAgentCatalog() {
        settingsPage = "add"
        focusedProviderID = nil
        withAnimation(.easeInOut(duration: 0.16)) { isShowingSettings = true }
        onLayoutChange?()
    }

    func openManageSettings(focusing providerID: String? = nil) {
        settingsPage = "manage"
        focusedProviderID = providerID
        withAnimation(.easeInOut(duration: 0.16)) { isShowingSettings = true }
        onLayoutChange?()
    }

    func closeInlineSettings() {
        onReleaseKeyFocus?()
        focusedProviderID = nil
        holdPanelUntil = Date().addingTimeInterval(1.2)
        withAnimation(.easeInOut(duration: 0.16)) { isShowingSettings = false }
        onExitInlineSettings?()
        onLayoutChange?()
    }

    func applyInteractiveLoginResult(_ freshItem: QuotaItem) {
        if let idx = items.firstIndex(where: { $0.id == freshItem.id }) {
            items[idx] = freshItem
        } else {
            items.append(freshItem)
            reorderItemsInPlace()
        }
        let ts = Date()
        lastUpdated = ts
        Self.saveDiskCache(items: items, updatedAt: ts)
        onStatusChange?(mostUrgentItem)
        onLayoutChange?()
        Task { await refresh(force: true) }
    }

    func connectCopilotViaGHCLI() {
        Task { @MainActor in
            if let tok = await PublicBalanceProviders.fetchGHCLIToken(), !tok.isEmpty {
                prefs.setCredential(tok, for: "copilotToken", immediate: true)
                prefs.setProviderEnabled("copilot", true)
            } else {
                openManageSettings(focusing: "copilot")
            }
        }
    }

    func performCardAction(_ item: QuotaItem) {
        if let desc = ProviderCatalog.byID[item.id],
           let webProvider = desc.webLoginProvider,
           item.actionKind?.hasPrefix("login_") == true
        {
            WebLoginController.shared.presentLogin(for: webProvider) { [weak self] fresh in
                self?.applyInteractiveLoginResult(fresh)
            }
            return
        }

        switch item.actionKind {
        case "connect_copilot":
            connectCopilotViaGHCLI()
        case "auth_desktop":
            authorizeDesktopKeychain(preferredID: item.id)
        case "open_app":
            if let desc = ProviderCatalog.byID[item.id],
               case .desktopKeychain(let bundleIDs, let appNames) = desc.authStyle,
               let url = ProviderConstants.findInstalledAppURL(bundleIDs: bundleIDs, appNames: appNames)
            {
                NSWorkspace.shared.open(url)
            }
        case "open_settings":
            openManageSettings(focusing: item.id)
        case "retry":
            Task { await refresh(force: true) }
        default:
            openAddAgentCatalog()
        }
    }

    func authorizeDesktopKeychain(preferredID: String) {
        guard !isPerformingModalAction else { return }
        isPerformingModalAction = true
        let savedIME = InputMethodGuard.currentActiveIMESourceID()
        let originPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if preferredID == "qoder" {
                _ = QoderAdapter.checkStatus(interactive: true)
            } else if preferredID == "qwenwork" {
                _ = QwenWorkAdapter.checkStatus(interactive: true)
            }
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.isPerformingModalAction = false
                strongSelf.holdPanelUntil = Date().addingTimeInterval(3.5)
                strongSelf.onEnsurePanelVisible?()
                InputMethodGuard.restoreIMEAfterModal(savedIMESourceID: savedIME, expectedFrontmostPID: originPID)
                await HoverDataFetcher.clearDesktopGate(preferredID)
                await strongSelf.refresh(force: true)
            }
        }
    }

    func moveItem(fromID: String, toID: String) {
        prefs.moveProvider(fromID: fromID, toID: toID)
    }

    func removeItemFromPanel(_ id: String) {
        holdPanelUntil = Date().addingTimeInterval(1.8)
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.85)) {
            items.removeAll { $0.id == id }
        }
        prefs.setProviderEnabled(id, false)
        onStatusChange?(mostUrgentItem)
        onLayoutChange?()
    }

    func reorderItemsInPlace() {
        let rank = Dictionary(
            prefs.normalizedProviderOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { _, latest in latest }
        )
        withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.84)) {
            items.sort { (rank[$0.id] ?? 999) < (rank[$1.id] ?? 999) }
        }
        if let ts = lastUpdated {
            Self.saveDiskCache(items: items, updatedAt: ts)
        }
    }

    func restartRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(30, prefs.refreshIntervalSeconds))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                guard !strongSelf.isSystemSleeping else { return }
                await strongSelf.refresh(force: false)
            }
        }
        t.tolerance = min(15, interval * 0.1)
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func setPanelVisible(_ visible: Bool) {
        clockTimer?.invalidate()
        clockTimer = nil
        guard visible else { return }
        self.now = Date()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in strongSelf.now = Date() }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
    }

    private func setupSleepWakeLifecycle() {
        let nc = NSWorkspace.shared.notificationCenter
        let sleepObs = nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isSystemSleeping = true }
        }
        let screenSleepObs = nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isSystemSleeping = true }
        }
        let screenWakeObs = nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSystemSleeping = false
                self.now = Date()
            }
        }
        let wakeObs = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.isSystemSleeping = false
                strongSelf.now = Date()
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                await strongSelf.refresh(force: true)
            }
        }
        wakeObservers = [sleepObs, screenSleepObs, screenWakeObs, wakeObs]
    }

    var gridItems: [QuotaItem] { items.filter { $0.kind != "balance" } }
    var balanceItems: [QuotaItem] { items.filter { $0.kind == "balance" } }

    var mostUrgentItem: QuotaItem? {
        gridItems.filter { !$0.isPending }.min(by: { $0.remainingPercent < $1.remainingPercent })
    }

    func relativeUpdateText() -> String {
        guard let lastUpdated else { return items.isEmpty ? "" : "同步中…" }
        let sec = max(0, Int(now.timeIntervalSince(lastUpdated)))
        if sec < 20 { return "刚刚更新" }
        if sec < 3600 { return "\(max(1, sec / 60))分钟前" }
        if sec < 86400 { return "\(sec / 3600)小时前" }
        return "\(sec / 86400)天前"
    }

    func refreshIfStale(maxAge: TimeInterval = 30) async {
        self.now = Date()
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < maxAge,
           Date().timeIntervalSince(lastRefreshAttemptAt) < maxAge
        {
            return
        }
        await refresh(force: false)
    }

    static func defaultActionKind(for desc: ProviderDescriptor, outcome: FetchOutcome?) -> String? {
        if let outcome {
            switch outcome {
            case .success: return nil
            case .needsKeychainAuth: return "auth_desktop"
            case .transientFailure: return "retry"
            case .unconfigured, .authExpired: break
            }
        }
        switch desc.authStyle {
        case .webLogin(let p):
            return "login_\(p.rawValue)"
        case .hybridDSH:
            return "login_deepseek"
        case .hybridCopilot:
            return PublicBalanceProviders.hasGHCLIInstalled ? "connect_copilot" : "open_settings"
        case .desktopKeychain:
            return outcome == nil ? "auth_desktop" : "open_app"
        case .apiKey:
            return "open_settings"
        }
    }

    func refresh(force: Bool) async {
        if isRefreshing {
            if force { needsFollowUpRefresh = true }
            return
        }
        isRefreshing = true
        lastRefreshAttemptAt = Date()

        let previousCount = items.count
        let prevByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let orderedEnabled = prefs.normalizedProviderOrder.compactMap { id -> ProviderDescriptor? in
            guard prefs.isProviderEnabled(id) else { return nil }
            return ProviderCatalog.byID[id]
        }
        let credsSnapshot = prefs.credentials

        var outcomesByID: [String: FetchOutcome] = [:]
        await withTaskGroup(of: (String, FetchOutcome).self) { group in
            for desc in orderedEnabled {
                group.addTask {
                    let out = await PublicBalanceProviders.fetch(for: desc, credentials: credsSnapshot)
                    return (desc.id, out)
                }
            }
            for await (id, outcome) in group {
                outcomesByID[id] = outcome
            }
        }

        var anyFreshSuccess = false
        var next: [QuotaItem] = []

        for desc in orderedEnabled {
            let outcome = outcomesByID[desc.id]
            let act = Self.defaultActionKind(for: desc, outcome: outcome)
            let displayName: String = {
                if desc.id == "dsh" {
                    let dsKey = (credsSnapshot["deepseek"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return dsKey.isEmpty ? "DSH" : "DeepSeek"
                }
                return desc.shortName
            }()

            guard let outcome else {
                next.append(Self.makePlaceholder(for: desc, name: displayName, label: "周期", subText: nil, actionKind: act))
                continue
            }

            switch outcome {
            case .success(let fresh):
                anyFreshSuccess = true
                next.append(fresh)
            case .transientFailure(let reason):
                if var prev = prevByID[desc.id], !prev.isPending {
                    prev.isStale = true
                    next.append(prev)
                } else {
                    next.append(Self.makePlaceholder(for: desc, name: displayName, label: "周期", subText: reason, actionKind: act))
                }
            case .needsKeychainAuth(let reason):
                next.append(Self.makePlaceholder(for: desc, name: displayName, label: "待授权", subText: reason, actionKind: act))
            case .authExpired(let reason):
                next.append(Self.makePlaceholder(for: desc, name: displayName, label: "过期", subText: reason, actionKind: act))
            case .unconfigured(let hint):
                next.append(Self.makePlaceholder(for: desc, name: displayName, label: "未绑定", subText: hint, actionKind: act))
            }
        }

        self.items = next
        if anyFreshSuccess || next.isEmpty {
            let ts = Date()
            self.lastUpdated = ts
            Self.saveDiskCache(items: next, updatedAt: ts)
        }
        self.now = Date()
        self.onStatusChange?(self.mostUrgentItem)
        if next.count != previousCount {
            self.onLayoutChange?()
        }

        isRefreshing = false
        if needsFollowUpRefresh {
            needsFollowUpRefresh = false
            await refresh(force: true)
        }
    }

    private static func makePlaceholder(
        for desc: ProviderDescriptor,
        name: String? = nil,
        label: String? = nil,
        subText: String?,
        actionKind: String?
    ) -> QuotaItem {
        QuotaItem(
            id: desc.id,
            name: name ?? desc.shortName,
            kind: desc.kind,
            windowLabel: desc.kind == "balance" ? nil : (label ?? desc.defaultWindowLabel),
            remainingPercent: -1,
            remainingText: "--",
            subText: subText,
            resetsAt: nil,
            status: "pending",
            isStale: false,
            actionKind: actionKind
        )
    }

    private static func loadDiskCache() -> PersistedSnapshotCache? {
        guard let data = try? Data(contentsOf: AppPreferences.snapshotCacheURL) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PersistedSnapshotCache.self, from: data)
    }

    private static func saveDiskCache(items: [QuotaItem], updatedAt: Date) {
        let valid = items.filter { !$0.isPending }
        guard !valid.isEmpty else { return }
        let dir = AppPreferences.appConfigDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(PersistedSnapshotCache(updatedAt: updatedAt, items: valid)) {
            try? data.write(to: AppPreferences.snapshotCacheURL, options: [.atomic])
            chmod(AppPreferences.snapshotCacheURL.path, 0o600)
        }
    }

    private static func mergeCachedWithPlaceholders(cached: [QuotaItem], prefs: AppPreferences) -> [QuotaItem] {
        let byID = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return buildPlaceholders(prefs: prefs).map { placeholder in
            byID[placeholder.id] ?? placeholder
        }
    }

    static func buildPlaceholders(prefs: AppPreferences) -> [QuotaItem] {
        prefs.normalizedProviderOrder.compactMap { id in
            guard prefs.isProviderEnabled(id), let desc = ProviderCatalog.byID[id] else { return nil }
            return makePlaceholder(
                for: desc,
                subText: "同步中…",
                actionKind: defaultActionKind(for: desc, outcome: nil)
            )
        }
    }
}
