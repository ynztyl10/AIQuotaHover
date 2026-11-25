import AppKit
import SwiftUI
import WebKit

enum WebLoginProvider: String {
    case gemini
    case claude
    case chatgpt
    case cursor
    case deepseek
    case workbuddy

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        case .cursor: return "Cursor"
        case .deepseek: return "DeepSeek"
        case .workbuddy: return "WorkBuddy"
        }
    }

    var startURL: URL {
        switch self {
        case .gemini:    return URL(string: "https://gemini.google.com/usage")!
        case .claude:    return URL(string: "https://claude.ai/settings/usage")!
        case .chatgpt:   return URL(string: "https://chatgpt.com/")!
        case .cursor:    return URL(string: "https://www.cursor.com/dashboard")!
        case .deepseek:  return URL(string: "https://platform.deepseek.com/usage")!
        case .workbuddy: return URL(string: "https://www.codebuddy.cn/profile")!
        }
    }

    var secretStorageKey: String {
        switch self {
        case .gemini:    return "geminiCookie"
        case .claude:    return "claudeCookie"
        case .chatgpt:   return "chatgptWebToken"
        case .cursor:    return "cursorCookie"
        case .deepseek:  return "deepseekWebToken"
        case .workbuddy: return "workbuddy"
        }
    }

    var clearDomainMatchers: [String] {
        switch self {
        case .gemini:    return ["google.com"]
        case .claude:    return ["claude.ai"]
        case .chatgpt:   return ["chatgpt.com", "openai.com"]
        case .cursor:    return ["cursor.com"]
        case .deepseek:  return ["deepseek.com"]
        case .workbuddy: return ["codebuddy.cn", "workbuddy.cn", "workbuddy.ai"]
        }
    }
}

/// Ephemeral-lifecycle native login sheet:
/// Creates a `WKWebView` ONLY while signing in and destroys it immediately on close (`0 MB` idle WebKit RAM).
@MainActor
final class WebLoginController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let shared = WebLoginController()

    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusLabel: NSTextField?
    private var pollTimer: Timer?
    private var activeProvider: WebLoginProvider?
    private var sessionID: UInt64 = 0
    private var isVerifying: Bool = false
    private var hasCompleted: Bool = false
    private var onSuccess: ((QuotaItem) -> Void)?
    private var previousFrontmostApp: NSRunningApplication?
    private var savedIMESourceID: String?

    var isWindowVisible: Bool {
        window?.isVisible == true
    }

    private override init() {
        super.init()
    }

    func presentLogin(for provider: WebLoginProvider, onSuccess: @escaping (QuotaItem) -> Void) {
        tearDownWebView(restorePreviousApp: false)
        self.sessionID &+= 1

        self.savedIMESourceID = InputMethodGuard.currentActiveIMESourceID()
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            self.previousFrontmostApp = front
        } else {
            self.previousFrontmostApp = nil
        }

        self.activeProvider = provider
        self.onSuccess = onSuccess
        self.isVerifying = false
        self.hasCompleted = false

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 620), configuration: config)
        wv.customUserAgent = ProviderConstants.safariUserAgent
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.translatesAutoresizingMaskIntoConstraints = false
        self.webView = wv

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 664))
        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: "请在下方登录 \(provider.displayName)，成功后将自动同步额度并关闭窗口")
        status.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false
        self.statusLabel = status

        let switchBtn = NSButton(title: "切换账号", target: self, action: #selector(handleClearAndReload))
        switchBtn.bezelStyle = .rounded
        switchBtn.controlSize = .small
        switchBtn.translatesAutoresizingMaskIntoConstraints = false

        let clipBtn = NSButton(title: "从剪贴板导入", target: self, action: #selector(handleClipboardFallback))
        clipBtn.bezelStyle = .rounded
        clipBtn.controlSize = .small
        clipBtn.toolTip = "若企业安全策略拦截内置登录，可在默认浏览器复制请求 cURL 后点此导入"
        clipBtn.translatesAutoresizingMaskIntoConstraints = false
        clipBtn.isHidden = (provider == .chatgpt || provider == .deepseek)

        topBar.addSubview(status)
        topBar.addSubview(clipBtn)
        topBar.addSubview(switchBtn)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(topBar)
        container.addSubview(divider)
        container.addSubview(wv)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: container.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 42),

            status.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 14),
            status.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: clipBtn.leadingAnchor, constant: -8),

            switchBtn.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            switchBtn.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            clipBtn.trailingAnchor.constraint(equalTo: switchBtn.leadingAnchor, constant: -6),
            clipBtn.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            divider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            wv.topAnchor.constraint(equalTo: divider.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 664),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "登录绑定 \(provider.displayName)"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = container
        win.center()
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        wv.load(URLRequest(url: provider.startURL))
        startVerificationPoll()
    }

    func windowWillClose(_ notification: Notification) {
        tearDownWebView(restorePreviousApp: true)
    }

    private func tearDownWebView(restorePreviousApp: Bool = true) {
        self.sessionID &+= 1
        let wasOurAppActive = NSApp.isActive
        pollTimer?.invalidate()
        pollTimer = nil
        onSuccess = nil
        activeProvider = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        if let win = window {
            win.delegate = nil
            win.orderOut(nil)
        }
        window = nil
        statusLabel = nil
        isVerifying = false
        hasCompleted = true

        let prev = previousFrontmostApp
        let savedIME = savedIMESourceID
        previousFrontmostApp = nil
        savedIMESourceID = nil

        if restorePreviousApp, wasOurAppActive {
            let targetPID = prev?.processIdentifier
            if let prev, !prev.isTerminated {
                prev.activate()
            }
            InputMethodGuard.restoreIMEAfterModal(savedIMESourceID: savedIME, expectedFrontmostPID: targetPID)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            Task { @MainActor in webView.load(URLRequest(url: url)) }
        }
        return nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            await self?.checkSessionIfOnTargetHost()
        }
    }

    private func startVerificationPoll() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 2.2, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in await strongSelf.checkSessionIfOnTargetHost() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    @objc private func handleClearAndReload() {
        guard let provider = activeProvider, let wv = webView else { return }
        self.sessionID &+= 1
        let clearSession = self.sessionID
        self.isVerifying = false
        self.hasCompleted = false
        pollTimer?.invalidate()
        pollTimer = nil
        wv.stopLoading()
        statusLabel?.stringValue = "正在清除当前会话与存储以切换账号…"

        let matchers = provider.clearDomainMatchers
        let dataStore = wv.configuration.websiteDataStore
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        dataStore.fetchDataRecords(ofTypes: allTypes) { [weak self] records in
            let toRemove = records.filter { rec in
                let name = rec.displayName.lowercased()
                return matchers.contains { name.contains($0) }
            }
            dataStore.removeData(ofTypes: allTypes, for: toRemove) {
                let cookieStore = dataStore.httpCookieStore
                cookieStore.getAllCookies { cookies in
                    let group = DispatchGroup()
                    for c in cookies where matchers.contains(where: { c.domain.lowercased().contains($0) }) {
                        group.enter()
                        cookieStore.delete(c) { group.leave() }
                    }
                    group.notify(queue: .main) {
                        Task { @MainActor in
                            guard let self, self.sessionID == clearSession, self.webView === wv else { return }
                            self.statusLabel?.stringValue = "请登录新的 \(provider.displayName) 账号…"
                            wv.load(URLRequest(url: provider.startURL))
                            self.startVerificationPoll()
                        }
                    }
                }
            }
        }
    }

    @objc private func handleClipboardFallback() {
        guard let provider = activeProvider else { return }
        let expectedSession = self.sessionID
        let raw = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedInput = (provider == .cursor && !raw.contains("=") && raw.count > 16)
            ? "WorkosCursorSessionToken=\(raw)"
            : raw

        guard AppPreferences.normalizedCookieHeader(from: normalizedInput) != nil else {
            NSWorkspace.shared.open(provider.startURL)
            statusLabel?.stringValue = "已在浏览器打开用量页：复制请求 Copy as cURL 后再点「从剪贴板导入」"
            return
        }

        statusLabel?.stringValue = "正在验证剪贴板凭证…"
        let secretKey = provider.secretStorageKey
        let prevSecret = AppPreferences.shared.credential(for: secretKey)
        let valueToSave = (provider == .workbuddy) ? raw : normalizedInput

        Task { @MainActor [weak self] in
            let outcome: FetchOutcome
            switch provider {
            case .gemini:    outcome = await PublicBalanceProviders.fetchGemini(cookieInput: normalizedInput)
            case .claude:    outcome = await PublicBalanceProviders.fetchClaude(cookieInput: normalizedInput, allowLocalOAuth: false)
            case .cursor:    outcome = await PublicBalanceProviders.fetchCursor(cookieInput: normalizedInput)
            case .workbuddy: outcome = await PublicBalanceProviders.fetchWorkBuddy(authInput: raw)
            case .chatgpt, .deepseek: return
            }

            guard let self, self.sessionID == expectedSession, !self.hasCompleted else { return }
            if case .success(let item) = outcome {
                if AppPreferences.shared.credential(for: secretKey) == prevSecret {
                    AppPreferences.shared.setCredential(valueToSave, for: secretKey)
                }
                self.finishWithSuccess(item, expectedSession: expectedSession)
            } else {
                self.statusLabel?.stringValue = "剪贴板凭证无效或已过期，请重新复制"
            }
        }
    }

    private func saveSecretPreservingRotation(provider: WebLoginProvider, candidate: String, preFetchValue: String) {
        let key = provider.secretStorageKey
        if AppPreferences.shared.credential(for: key) == preFetchValue {
            AppPreferences.shared.setCredential(candidate, for: key)
        }
    }

    private func checkSessionIfOnTargetHost() async {
        guard !hasCompleted, !isVerifying,
              let provider = activeProvider,
              let wv = webView,
              let currentHost = wv.url?.host?.lowercased()
        else { return }

        let expectedSession = self.sessionID

        switch provider {
        case .gemini:
            guard currentHost == "gemini.google.com" else { return }
            isVerifying = true
            defer { if self.sessionID == expectedSession { isVerifying = false } }

            let cookies = await wv.configuration.websiteDataStore.httpCookieStore.allCookiesAsync()
            guard self.sessionID == expectedSession, self.webView === wv else { return }
            let googleCookies = cookies.filter { $0.domain.hasSuffix("google.com") }
            guard googleCookies.contains(where: { $0.name == "SID" || $0.name == "__Secure-1PSID" }) else { return }

            let header = Self.serializeCookies(googleCookies)
            let prev = AppPreferences.shared.credential(for: provider.secretStorageKey)
            statusLabel?.stringValue = "检测到 Google 登录态，正在读取 Gemini 剩余额度…"
            let outcome = await PublicBalanceProviders.fetchGemini(cookieInput: header)
            guard self.sessionID == expectedSession, self.webView === wv, !self.hasCompleted else { return }
            switch outcome {
            case .success(let item):
                saveSecretPreservingRotation(provider: provider, candidate: header, preFetchValue: prev)
                finishWithSuccess(item, expectedSession: expectedSession)
            case .unconfigured(let msg):
                statusLabel?.stringValue = "⚠️ \(msg)（可点右上角「切换账号」更换订阅账号）"
            default:
                break
            }

        case .claude:
            guard currentHost.hasSuffix("claude.ai") && !currentHost.contains("login") else { return }
            isVerifying = true
            defer { if self.sessionID == expectedSession { isVerifying = false } }

            let cookies = await wv.configuration.websiteDataStore.httpCookieStore.allCookiesAsync()
            guard self.sessionID == expectedSession, self.webView === wv else { return }
            let claudeCookies = cookies.filter { $0.domain.hasSuffix("claude.ai") }
            guard claudeCookies.contains(where: { $0.name == "sessionKey" }) else { return }

            let header = Self.serializeCookies(claudeCookies)
            let prev = AppPreferences.shared.credential(for: provider.secretStorageKey)
            statusLabel?.stringValue = "检测到 Claude 登录态，正在读取剩余额度…"
            let outcome = await PublicBalanceProviders.fetchClaude(cookieInput: header, allowLocalOAuth: false)
            guard self.sessionID == expectedSession, self.webView === wv, !self.hasCompleted else { return }
            if case .success(let item) = outcome {
                saveSecretPreservingRotation(provider: provider, candidate: header, preFetchValue: prev)
                finishWithSuccess(item, expectedSession: expectedSession)
            }

        case .chatgpt:
            guard currentHost == "chatgpt.com" else { return }
            isVerifying = true
            defer { if self.sessionID == expectedSession { isVerifying = false } }

            let script = """
            const r = await fetch('/api/auth/session', { credentials: 'include' });
            if (!r.ok) return '';
            const j = await r.json();
            return j.accessToken || '';
            """
            guard let token = (try? await wv.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)) as? String,
                  !token.isEmpty,
                  self.sessionID == expectedSession, self.webView === wv
            else { return }

            statusLabel?.stringValue = "检测到 ChatGPT 登录态，正在读取剩余额度…"
            let outcome = await PublicBalanceProviders.fetchChatGPTWithWebToken(token)
            guard self.sessionID == expectedSession, self.webView === wv, !self.hasCompleted else { return }
            if case .success(let item) = outcome {
                AppPreferences.shared.setCredential(token, for: provider.secretStorageKey)
                finishWithSuccess(item, expectedSession: expectedSession)
            }

        case .cursor:
            guard currentHost.hasSuffix("cursor.com") && !currentHost.contains("authenticator") else { return }
            isVerifying = true
            defer { if self.sessionID == expectedSession { isVerifying = false } }

            let cookies = await wv.configuration.websiteDataStore.httpCookieStore.allCookiesAsync()
            guard self.sessionID == expectedSession, self.webView === wv else { return }
            let cursorCookies = cookies.filter { $0.domain.hasSuffix("cursor.com") }
            guard cursorCookies.contains(where: { $0.name == "WorkosCursorSessionToken" }) else { return }

            let header = Self.serializeCookies(cursorCookies)
            let prev = AppPreferences.shared.credential(for: provider.secretStorageKey)
            statusLabel?.stringValue = "检测到 Cursor 登录态，正在同步月度额度…"
            let outcome = await PublicBalanceProviders.fetchCursor(cookieInput: header)
            guard self.sessionID == expectedSession, self.webView === wv, !self.hasCompleted else { return }
            if case .success(let item) = outcome {
                saveSecretPreservingRotation(provider: provider, candidate: header, preFetchValue: prev)
                finishWithSuccess(item, expectedSession: expectedSession)
            }

        case .deepseek:
            guard currentHost == "platform.deepseek.com" else { return }
            let path = wv.url?.path.lowercased() ?? ""
            guard !path.contains("sign_in") && !path.contains("login") else { return }
            isVerifying = true
            defer { if self.sessionID == expectedSession { isVerifying = false } }

            let script = """
            try {
              for (let i = 0; i < localStorage.length; i++) {
                const k = localStorage.key(i);
                const v = localStorage.getItem(k);
                if (!k || !v) continue;
                if (k === 'deepseek-platform:userToken' || k === 'userToken' || k.toLowerCase().includes('usertoken')) {
                  try {
                    const parsed = JSON.parse(v);
                    if (typeof parsed === 'string' && parsed.length > 10) return parsed;
                    if (parsed && typeof parsed.value === 'string' && parsed.value.length > 10) return parsed.value;
                    if (parsed && typeof parsed.token === 'string' && parsed.token.length > 10) return parsed.token;
                  } catch {
                    if (v.length > 10) return v;
                  }
                }
              }
            } catch {}
            return '';
            """
            guard let token = (try? await wv.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)) as? String,
                  !token.isEmpty,
                  self.sessionID == expectedSession, self.webView === wv
            else { return }

            statusLabel?.stringValue = "检测到 DeepSeek 平台登录态，正在读取实时余额…"
            let outcome = await PublicBalanceProviders.fetchDeepSeekWebBalance(userToken: token)
            guard self.sessionID == expectedSession, self.webView === wv, !self.hasCompleted else { return }
            if case .success(let item) = outcome {
                AppPreferences.shared.setCredential(token, for: provider.secretStorageKey)
                finishWithSuccess(item, expectedSession: expectedSession)
            }

        case .workbuddy:
            let activeDomain: String
            if currentHost.hasSuffix("codebuddy.cn") { activeDomain = "codebuddy.cn" }
            else if currentHost.hasSuffix("workbuddy.cn") { activeDomain = "workbuddy.cn" }
            else if currentHost.hasSuffix("workbuddy.ai") { activeDomain = "workbuddy.ai" }
            else { return }

            let path = wv.url?.path.lowercased() ?? ""
            guard !path.contains("login") && !path.contains("signin") else { return }
            isVerifying = true
            defer { if self.sessionID == expectedSession { isVerifying = false } }

            let cookies = await wv.configuration.websiteDataStore.httpCookieStore.allCookiesAsync()
            guard self.sessionID == expectedSession, self.webView === wv else { return }
            let buddyCookies = cookies.filter {
                let d = $0.domain.lowercased()
                return d == activeDomain || d.hasSuffix(".\(activeDomain)")
            }
            let cookieHeader = Self.serializeCookies(buddyCookies)

            let tokenScript = """
            try {
              for (const storage of [localStorage, sessionStorage]) {
                for (let i = 0; i < storage.length; i++) {
                  const k = storage.key(i);
                  const v = storage.getItem(k);
                  if (!k || !v) continue;
                  const kl = k.toLowerCase();
                  if (kl.includes('token') || kl.includes('auth') || kl.includes('jwt')) {
                    try {
                      const p = JSON.parse(v);
                      if (typeof p === 'string' && p.length > 16) return p;
                      for (const f of ['access_token', 'accessToken', 'token', 'jwt', 'value']) {
                        if (p && typeof p[f] === 'string' && p[f].length > 16) return p[f];
                      }
                    } catch {
                      if (v.length > 16 && !v.includes(' ')) return v;
                    }
                  }
                }
              }
            } catch {}
            return '';
            """
            let jsToken = ((try? await wv.callAsyncJavaScript(tokenScript, arguments: [:], in: nil, contentWorld: .page)) as? String) ?? ""
            guard self.sessionID == expectedSession, self.webView === wv else { return }
            guard !cookieHeader.isEmpty || !jsToken.isEmpty else { return }

            var segments: [String] = ["Domain=\(activeDomain)"]
            if !jsToken.isEmpty { segments.append("Bearer \(jsToken)") }
            if !cookieHeader.isEmpty { segments.append("Cookie: \(cookieHeader)") }
            let combined = segments.joined(separator: "||")

            statusLabel?.stringValue = "检测到 WorkBuddy 登录态，正在读取剩余积分…"
            let outcome = await PublicBalanceProviders.fetchWorkBuddy(authInput: combined)
            guard self.sessionID == expectedSession, self.webView === wv, !self.hasCompleted else { return }
            if case .success(let item) = outcome {
                AppPreferences.shared.setCredential(combined, for: provider.secretStorageKey)
                finishWithSuccess(item, expectedSession: expectedSession)
            }
        }
    }

    private func finishWithSuccess(_ item: QuotaItem, expectedSession: UInt64) {
        guard self.sessionID == expectedSession, !hasCompleted else { return }
        hasCompleted = true
        pollTimer?.invalidate()
        pollTimer = nil
        statusLabel?.stringValue = "✅ \(item.name) 绑定成功（剩余 \(item.remainingText)）"
        let callback = onSuccess
        onSuccess = nil
        callback?(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.sessionID == expectedSession else { return }
            self.tearDownWebView()
        }
    }

    private static func serializeCookies(_ cookies: [HTTPCookie]) -> String {
        var latestByName: [String: String] = [:]
        var orderedNames: [String] = []
        for c in cookies where !c.name.isEmpty && !c.value.isEmpty {
            if latestByName[c.name] == nil { orderedNames.append(c.name) }
            latestByName[c.name] = c.value
        }
        return orderedNames.compactMap { name in
            latestByName[name].map { "\(name)=\($0)" }
        }.joined(separator: "; ")
    }
}

private extension WKHTTPCookieStore {
    func allCookiesAsync() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            self.getAllCookies { cont.resume(returning: $0) }
        }
    }
}
