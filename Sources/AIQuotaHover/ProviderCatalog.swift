import AppKit
import Foundation
import QuotaAdapters

enum ProviderConstants {
    static let chromeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
    static let claudeCodeUserAgent = "claude-code/2.1.0"
    static let copilotEditorVersion = "vscode/1.105.0"
    static let copilotPluginVersion = "copilot-chat/0.32.0"
    static let copilotUserAgent = "GitHubCopilotChat/0.32.0"

    /// Google Gemini Web frontend persisted GraphQL query signature (`/usage` pools).
    static let geminiGraphQLSignature = "2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g="
    static let geminiGraphQLVariables = #"{"g1Request":{"entrypoints":["GEMINI_USAGE_SETTINGS_UPGRADE_BANNER"]},"workspaceRequest":{"recommendationsForSurfaceRequests":[]}}"#

    static let volcArkHost = "open.volcengineapi.com"
    static let volcArkRegion = "cn-beijing"
    static let volcArkService = "ark"
    static let volcArkVersion = "2024-01-01"

    static func findExecutable(_ binaryName: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var searchDirs: [String] = []
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            searchDirs.append(contentsOf: envPath.components(separatedBy: ":").filter { !$0.isEmpty })
        }
        searchDirs.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "\(home)/.local/bin",
            "\(home)/.nix-profile/bin",
            "/run/current-system/sw/bin"
        ])
        var seen = Set<String>()
        for dir in searchDirs where seen.insert(dir).inserted {
            let candidate = (dir as NSString).appendingPathComponent(binaryName)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func findInstalledAppURL(bundleIDs: [String], appNames: [String]) -> URL? {
        for bid in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return url
            }
        }
        let fm = FileManager.default
        let homeApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let appDirs = [URL(fileURLWithPath: "/Applications"), homeApps]
        for dir in appDirs {
            for name in appNames {
                let candidate = dir.appendingPathComponent(name.hasSuffix(".app") ? name : "\(name).app")
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    static func isAppOrSupportPresent(
        bundleIDs: [String] = [],
        appNames: [String] = [],
        homeRelativePaths: [String] = []
    ) -> Bool {
        if findInstalledAppURL(bundleIDs: bundleIDs, appNames: appNames) != nil {
            return true
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return homeRelativePaths.contains { rel in
            fm.fileExists(atPath: home.appendingPathComponent(rel).path)
        }
    }
}

enum BalancePolicy {
    static func makeBalanceItem(
        id: String,
        name: String,
        amount: Double,
        currency: String,
        subtitle: String
    ) -> QuotaItem {
        let safeAmount = max(0, amount)
        let isUSD = currency.uppercased() == "USD" || currency == "$"
        let symbol = isUSD ? "$" : "¥"
        let warnLine = isUSD ? AdapterConstants.usdWarnThreshold : AdapterConstants.cnyWarnThreshold
        let critLine = isUSD ? AdapterConstants.usdCriticalThreshold : AdapterConstants.cnyCriticalThreshold
        let status = safeAmount < critLine ? "critical" : (safeAmount < warnLine ? "warning" : "ok")
        let pct = safeAmount > critLine ? 100.0 : (safeAmount > 0 ? 25.0 : 0.0)

        return QuotaItem(
            id: id,
            name: name,
            kind: "balance",
            windowLabel: nil,
            remainingPercent: pct,
            remainingText: String(format: "%@%.2f", symbol, safeAmount),
            subText: subtitle,
            resetsAt: nil,
            status: status,
            isStale: false
        )
    }
}

enum ProviderAuthStyle {
    case webLogin(WebLoginProvider)
    case desktopKeychain(bundleIDs: [String], appNames: [String])
    case apiKey(placeholder: String, portalURL: String)
    case hybridCopilot(placeholder: String, portalURL: String)
    case hybridDSH(placeholder: String, portalURL: String)
}

struct ProviderDescriptor: Identifiable {
    let id: String
    let title: String
    let shortName: String
    let subtitle: String
    let kind: String              // "quota" | "balance"
    let defaultWindowLabel: String
    let primarySecretKey: String? // Key in `~/.config/ai-quota-hover/secrets.json`
    let secondarySecretKey: String?
    let authStyle: ProviderAuthStyle

    var needsManualKeyOnAdd: Bool {
        if case .apiKey = authStyle { return true }
        return false
    }

    var keyPlaceholder: String? {
        switch authStyle {
        case .apiKey(let ph, _), .hybridCopilot(let ph, _), .hybridDSH(let ph, _):
            return ph
        default:
            return nil
        }
    }

    var keyPortalURL: String? {
        switch authStyle {
        case .apiKey(_, let url), .hybridCopilot(_, let url), .hybridDSH(_, let url):
            return url
        default:
            return nil
        }
    }

    var webLoginProvider: WebLoginProvider? {
        switch authStyle {
        case .webLogin(let p): return p
        case .hybridDSH: return .deepseek
        default: return nil
        }
    }
}

enum ProviderCatalog {
    static let all: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: "cursor",
            title: "Cursor",
            shortName: "Cursor",
            subtitle: "网页一键登录 · 自动同步 Pro 月度快速额度",
            kind: "quota",
            defaultWindowLabel: "月",
            primarySecretKey: "cursorCookie",
            secondarySecretKey: nil,
            authStyle: .webLogin(.cursor)
        ),
        ProviderDescriptor(
            id: "claude",
            title: "Claude / Claude Code",
            shortName: "Claude",
            subtitle: "自动读本地 CLI 凭证或网页一键登录 · 5h/周配额",
            kind: "quota",
            defaultWindowLabel: "5h",
            primarySecretKey: "claudeCookie",
            secondarySecretKey: nil,
            authStyle: .webLogin(.claude)
        ),
        ProviderDescriptor(
            id: "chatgpt",
            title: "ChatGPT / Codex",
            shortName: "ChatGPT",
            subtitle: "本机 Codex 自动直连或网页一键登录 · 5h/周配额",
            kind: "quota",
            defaultWindowLabel: "周",
            primarySecretKey: "chatgptWebToken",
            secondarySecretKey: nil,
            authStyle: .webLogin(.chatgpt)
        ),
        ProviderDescriptor(
            id: "workbuddy",
            title: "WorkBuddy / CodeBuddy",
            shortName: "WorkBuddy",
            subtitle: "腾讯桌面办公 Agent · 网页扫码一键同步积分余量",
            kind: "quota",
            defaultWindowLabel: "积分",
            primarySecretKey: "workbuddy",
            secondarySecretKey: nil,
            authStyle: .webLogin(.workbuddy)
        ),
        ProviderDescriptor(
            id: "qoder",
            title: "Qoder",
            shortName: "Qoder",
            subtitle: "本机 Qoder 桌面端一键授权读取实时积分余量",
            kind: "quota",
            defaultWindowLabel: "积分",
            primarySecretKey: nil,
            secondarySecretKey: nil,
            authStyle: .desktopKeychain(
                bundleIDs: QoderAdapter.bundleIdentifiers,
                appNames: ["Qoder.app", "Qoder IDE.app"]
            )
        ),
        ProviderDescriptor(
            id: "qwenwork",
            title: "千问 Work",
            shortName: "千问Work",
            subtitle: "本机千问桌面端一键授权读取实时积分余量",
            kind: "quota",
            defaultWindowLabel: "积分",
            primarySecretKey: nil,
            secondarySecretKey: nil,
            authStyle: .desktopKeychain(
                bundleIDs: QwenWorkAdapter.bundleIdentifiers,
                appNames: ["QwenWorkCN.app"]
            )
        ),
        ProviderDescriptor(
            id: "dsh",
            title: "DSH 桌面端 / DeepSeek",
            shortName: "DSH / DeepSeek",
            subtitle: "支持 DeepSeek Harness 桌面端/CLI 直连或网页登录",
            kind: "balance",
            defaultWindowLabel: "余额",
            primarySecretKey: "deepseek",
            secondarySecretKey: "deepseekWebToken",
            authStyle: .hybridDSH(
                placeholder: "可选 DeepSeek API Key (留空走桌面端/网页登录)",
                portalURL: "https://platform.deepseek.com/api_keys"
            )
        ),
        ProviderDescriptor(
            id: "copilot",
            title: "GitHub Copilot",
            shortName: "Copilot",
            subtitle: "自动读取 IDE / gh 登录态 · 每月高级请求余量",
            kind: "quota",
            defaultWindowLabel: "月",
            primarySecretKey: "copilotToken",
            secondarySecretKey: nil,
            authStyle: .hybridCopilot(
                placeholder: "GitHub Token (gho_... / ghu_...)",
                portalURL: "https://github.com/settings/copilot"
            )
        ),
        ProviderDescriptor(
            id: "gemini",
            title: "Gemini Advanced",
            shortName: "Gemini",
            subtitle: "Google 账号一键网页登录 · 5h/周窗口余量",
            kind: "quota",
            defaultWindowLabel: "周期",
            primarySecretKey: "geminiCookie",
            secondarySecretKey: nil,
            authStyle: .webLogin(.gemini)
        ),
        ProviderDescriptor(
            id: "volcark",
            title: "豆包 / 火山方舟套餐",
            shortName: "豆包/方舟",
            subtitle: "字节官方 Agent / Coding Plan 席位 5h 与周余量%",
            kind: "quota",
            defaultWindowLabel: "5h",
            primarySecretKey: "volcark",
            secondarySecretKey: nil,
            authStyle: .apiKey(
                placeholder: "填入火山引擎 AK:SK (冒号分隔)",
                portalURL: "https://console.volcengine.com/iam/keymanage/"
            )
        ),
        ProviderDescriptor(
            id: "glm",
            title: "智谱 GLM (Coding Plan)",
            shortName: "智谱 GLM",
            subtitle: "官方监控直连 · 实时展示 5h 与周窗口配额%",
            kind: "quota",
            defaultWindowLabel: "5h",
            primarySecretKey: "glm",
            secondarySecretKey: nil,
            authStyle: .apiKey(
                placeholder: "粘贴智谱 BigModel API Key",
                portalURL: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys"
            )
        ),
        ProviderDescriptor(
            id: "minimax",
            title: "MiniMax (Coding Plan)",
            shortName: "MiniMax",
            subtitle: "官方 M-Plan 直连 · 实时展示 5h 与周窗口余量%",
            kind: "quota",
            defaultWindowLabel: "5h",
            primarySecretKey: "minimax",
            secondarySecretKey: nil,
            authStyle: .apiKey(
                placeholder: "粘贴 MiniMax Coding Plan Key",
                portalURL: "https://platform.minimaxi.com/user-center/payment/coding-plan"
            )
        ),
        ProviderDescriptor(
            id: "kimi",
            title: "Kimi / Kimi Code",
            shortName: "Kimi",
            subtitle: "智能双模 · 自动识别 Kimi Code 套餐余量或账户余额",
            kind: "quota",
            defaultWindowLabel: "周",
            primarySecretKey: "kimi",
            secondarySecretKey: nil,
            authStyle: .apiKey(
                placeholder: "粘贴 Kimi Code 或 Moonshot Key (sk-...)",
                portalURL: "https://platform.moonshot.cn/console/api-keys"
            )
        )
    ]

    /// Preserves default visual card priority order on dashboard.
    static let defaultOrder: [String] = [
        "chatgpt", "cursor", "claude", "workbuddy", "qoder", "qwenwork",
        "copilot", "gemini", "volcark", "glm", "minimax", "kimi", "dsh"
    ]

    static let byID: [String: ProviderDescriptor] = Dictionary(
        all.map { ($0.id, $0) },
        uniquingKeysWith: { _, latest in latest }
    )
}

struct LocalAppScanResult {
    let installedIDs: Set<String>
    let hasCodexAuth: Bool
    let hasClaudeCodeCreds: Bool
    let hasCopilotToken: Bool
    let hasGHCLI: Bool
    let hasDSHDesktopApp: Bool

    func isInstalled(_ id: String) -> Bool {
        installedIDs.contains(id)
    }

    static func scan() -> LocalAppScanResult {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        let hasCodexAuth = fm.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path)
        let hasChatGPT = hasCodexAuth || ProviderConstants.isAppOrSupportPresent(
            bundleIDs: ["com.openai.chat"],
            appNames: ["ChatGPT.app"]
        )

        let hasCursor = ProviderConstants.isAppOrSupportPresent(
            bundleIDs: ["com.todesktop.230313mzl4w4u92"],
            appNames: ["Cursor.app"],
            homeRelativePaths: ["Library/Application Support/Cursor"]
        )

        let hasClaudeCodeCreds = fm.fileExists(atPath: home.appendingPathComponent(".claude/.credentials.json").path)
        let hasClaude = hasClaudeCodeCreds || ProviderConstants.isAppOrSupportPresent(
            bundleIDs: ["com.anthropic.claudefordesktop"],
            appNames: ["Claude.app"],
            homeRelativePaths: [".claude"]
        )

        let hasWorkBuddy = ProviderConstants.isAppOrSupportPresent(
            appNames: ["WorkBuddy.app", "CodeBuddy.app"],
            homeRelativePaths: [".workbuddy", ".codebuddy", "Library/Application Support/WorkBuddy"]
        )

        let hasCopilotToken = PublicBalanceProviders.discoverLocalCopilotToken() != nil
        let hasGHCLI = ProviderConstants.findExecutable("gh") != nil

        let hasQoder = ProviderConstants.isAppOrSupportPresent(
            bundleIDs: QoderAdapter.bundleIdentifiers,
            appNames: ["Qoder.app", "Qoder IDE.app"],
            homeRelativePaths: ["Library/Application Support/com.qoder.app.stable"]
        )

        let hasQwenWork = ProviderConstants.isAppOrSupportPresent(
            bundleIDs: QwenWorkAdapter.bundleIdentifiers,
            appNames: ["QwenWorkCN.app"],
            homeRelativePaths: ["Library/Application Support/QwenWorkCN", "Library/Application Support/QoderWork"]
        )

        let hasDSHDesktop = DSHAdapter.hasDesktopAppInstalled
            || ProviderConstants.findInstalledAppURL(bundleIDs: DSHAdapter.bundleIdentifiers, appNames: ["DeepSeek Harness.app", "DSH.app"]) != nil
        let hasDSH = hasDSHDesktop || fm.fileExists(atPath: home.appendingPathComponent(".dsh").path)

        var installed = Set<String>()
        if hasChatGPT { installed.insert("chatgpt") }
        if hasCursor { installed.insert("cursor") }
        if hasClaude { installed.insert("claude") }
        if hasWorkBuddy { installed.insert("workbuddy") }
        if hasCopilotToken || hasGHCLI { installed.insert("copilot") }
        if hasQoder { installed.insert("qoder") }
        if hasQwenWork { installed.insert("qwenwork") }
        if hasDSH { installed.insert("dsh") }

        return LocalAppScanResult(
            installedIDs: installed,
            hasCodexAuth: hasCodexAuth,
            hasClaudeCodeCreds: hasClaudeCodeCreds,
            hasCopilotToken: hasCopilotToken,
            hasGHCLI: hasGHCLI,
            hasDSHDesktopApp: hasDSHDesktop
        )
    }
}
