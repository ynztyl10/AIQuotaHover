import CryptoKit
import Foundation

enum FetchOutcome {
    case success(QuotaItem)
    case needsKeychainAuth(String)
    case unconfigured(String)
    case authExpired(String)
    case transientFailure(String)
}

struct QuotaWindowCandidate {
    let idx: Int
    let tag: String
    let remainingPercent: Double
    let resetDate: Date?
    var customSubText: String? = nil
}

enum PublicBalanceProviders {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 22
        cfg.timeoutIntervalForResource = 28
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.httpAdditionalHeaders = ["Cache-Control": "no-cache"]
        return URLSession(configuration: cfg)
    }()

    // MARK: - Unified Catalog Dispatcher

    static func fetch(for desc: ProviderDescriptor, credentials: [String: String]) async -> FetchOutcome {
        let primary = desc.primarySecretKey.map { credentials[$0] ?? "" } ?? ""
        let secondary = desc.secondarySecretKey.map { credentials[$0] ?? "" } ?? ""

        switch desc.id {
        case "chatgpt":
            return await fetchChatGPT(webTokenFallback: primary)
        case "cursor":
            return await fetchCursor(cookieInput: primary)
        case "claude":
            return await fetchClaude(cookieInput: primary, allowLocalOAuth: true)
        case "workbuddy":
            return await fetchWorkBuddy(authInput: primary)
        case "copilot":
            return await fetchCopilot(savedToken: primary)
        case "gemini":
            return await fetchGemini(cookieInput: primary)
        case "qoder":
            return await HoverDataFetcher.fetchQoder()
        case "qwenwork":
            return await HoverDataFetcher.fetchQwenWork()
        case "volcark":
            return await fetchVolcArkPlan(akskInput: primary)
        case "glm":
            return await fetchGLM(apiKey: primary)
        case "minimax":
            return await fetchMiniMax(apiKey: primary)
        case "kimi":
            return await fetchKimi(apiKey: primary)
        case "dsh":
            let dsKey = primary.trimmingCharacters(in: .whitespacesAndNewlines)
            return dsKey.isEmpty
                ? await HoverDataFetcher.fetchDSH(webTokenFallback: secondary)
                : await fetchDeepSeekBalance(apiKey: dsKey)
        default:
            return .unconfigured("未知服务")
        }
    }

    // MARK: - Shared Window & HTTP Helpers

    private static func buildConstrainedQuotaItem(
        id: String,
        name: String,
        windows: [QuotaWindowCandidate]
    ) -> QuotaItem? {
        guard let constrained = windows.min(by: { $0.remainingPercent < $1.remainingPercent }) else {
            return nil
        }
        let other = windows.first(where: { $0.idx != constrained.idx })
        let clamped = min(100, max(0, constrained.remainingPercent))
        let sub = constrained.customSubText ?? other.map { "\($0.tag) \(Int($0.remainingPercent.rounded()))%" }

        return QuotaItem(
            id: id,
            name: name,
            kind: "quota",
            windowLabel: constrained.tag,
            remainingPercent: clamped,
            remainingText: "\(Int(clamped.rounded()))%",
            subText: sub,
            resetsAt: constrained.resetDate,
            status: HoverDataFetcher.statusFor(clamped),
            isStale: false
        )
    }

    private static func makeBearerRequest(url: URL, token: String, timeout: TimeInterval = 18) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private static func makeCookieRequest(url: URL, cookieHeader: String, referer: String? = nil, timeout: TimeInterval = 20) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(ProviderConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.httpShouldHandleCookies = false
        return req
    }

    // MARK: - 1. ChatGPT / Codex (Read-Only Local `auth.json` + Web Session)

    static func fetchChatGPTWithWebToken(_ webToken: String) async -> FetchOutcome {
        let trimmed = webToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")
        else {
            return .unconfigured("点击登录绑定账号")
        }
        return await executeChatGPTUsage(url: url, accessToken: trimmed, accountId: nil, expiredHint: "登录已过期 · 点击重新登录")
    }

    static func fetchChatGPT(webTokenFallback: String = "") async -> FetchOutcome {
        let webTrimmed = webTokenFallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !webTrimmed.isEmpty {
            let webRes = await fetchChatGPTWithWebToken(webTrimmed)
            if case .success = webRes { return webRes }
            if case .transientFailure = webRes { return webRes }
        }

        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let authURL = codexHome.appendingPathComponent("auth.json")

        guard FileManager.default.fileExists(atPath: authURL.path),
              let authData = try? Data(contentsOf: authURL),
              let authObj = (try? JSONSerialization.jsonObject(with: authData)) as? [String: Any],
              let tokens = authObj["tokens"] as? [String: Any],
              let diskAccessToken = (tokens["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !diskAccessToken.isEmpty
        else {
            return webTrimmed.isEmpty ? .unconfigured("点击登录账号") : .authExpired("登录已过期 · 点击重新登录")
        }

        let accountId = (tokens["account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usageURL = resolveChatGPTUsageURL(codexHome: codexHome)
        return await executeChatGPTUsage(
            url: usageURL,
            accessToken: diskAccessToken,
            accountId: accountId,
            expiredHint: "登录已过期 · 点击网页登录或运行 codex"
        )
    }

    private static func resolveChatGPTUsageURL(codexHome: URL) -> URL {
        let fallback = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let configURL = codexHome.appendingPathComponent("config.toml")
        guard let toml = try? String(contentsOf: configURL, encoding: .utf8) else { return fallback }

        for line in toml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.contains("chatgpt_base_url"),
                  let eq = trimmed.firstIndex(of: "=")
            else { continue }
            var val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if let hash = val.firstIndex(of: "#") {
                val = String(val[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            while val.hasSuffix("/") { val.removeLast() }
            guard !val.isEmpty else { continue }
            if (val.contains("chatgpt.com") || val.contains("chat.openai.com")) && !val.contains("/backend-api") {
                val += "/backend-api"
            }
            if let u = URL(string: "\(val)/wham/usage") { return u }
        }
        return fallback
    }

    private static func executeChatGPTUsage(url: URL, accessToken: String, accountId: String?, expiredHint: String) async -> FetchOutcome {
        var req = makeBearerRequest(url: url, token: accessToken, timeout: 22)
        req.setValue(ProviderConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .transientFailure("响应异常") }
            if http.statusCode == 401 || http.statusCode == 403 { return .authExpired(expiredHint) }
            guard http.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rateLimit = root["rate_limit"] as? [String: Any]
            else {
                return .transientFailure("HTTP \(http.statusCode)")
            }

            func parseWin(_ any: Any?, idx: Int, fallbackTag: String) -> QuotaWindowCandidate? {
                guard let w = any as? [String: Any],
                      let used = HoverDataFetcher.doubleVal(w["used_percent"])
                else { return nil }
                let secs = HoverDataFetcher.safeInt(w["limit_window_seconds"])
                let tag = secs.map { HoverDataFetcher.windowTag(minutes: max(1, $0 / 60)) } ?? fallbackTag
                var resetDate: Date?
                if let resetEpoch = HoverDataFetcher.doubleVal(w["reset_at"]), resetEpoch > 1_000_000_000 {
                    resetDate = Date(timeIntervalSince1970: resetEpoch)
                } else if let afterSec = HoverDataFetcher.doubleVal(w["reset_after_seconds"]), afterSec > 0 {
                    resetDate = Date().addingTimeInterval(afterSec)
                }
                return QuotaWindowCandidate(idx: idx, tag: tag, remainingPercent: 100.0 - used, resetDate: resetDate)
            }

            let wins = [
                parseWin(rateLimit["primary_window"], idx: 0, fallbackTag: "5h"),
                parseWin(rateLimit["secondary_window"], idx: 1, fallbackTag: "周")
            ].compactMap { $0 }

            if let item = buildConstrainedQuotaItem(id: "chatgpt", name: "ChatGPT", windows: wins) {
                return .success(item)
            }
            guard let limitReached = rateLimit["limit_reached"] as? Bool else {
                return .transientFailure("未解析到 ChatGPT 配额窗口")
            }
            let rem = limitReached ? 0.0 : 100.0
            return .success(QuotaItem(
                id: "chatgpt",
                name: "ChatGPT",
                kind: "quota",
                windowLabel: "周期",
                remainingPercent: rem,
                remainingText: limitReached ? "已触限" : "未触限",
                subText: limitReached ? "达到当前限制" : "可用状态正常",
                resetsAt: nil,
                status: HoverDataFetcher.statusFor(rem)
            ))
        } catch {
            return .transientFailure("请求超时 · 下周期重试")
        }
    }

    // MARK: - 2. Gemini Web Quota

    static func fetchGemini(cookieInput: String) async -> FetchOutcome {
        let trimmed = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unconfigured("点击登录 Google 账号") }
        guard let cookieHeader = AppPreferences.normalizedCookieHeader(from: trimmed) else {
            return .unconfigured("点击重新登录账号")
        }

        var comps = URLComponents(string: "https://gemini.google.com/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery")!
        comps.queryItems = [
            URLQueryItem(name: "query_signature", value: ProviderConstants.geminiGraphQLSignature),
            URLQueryItem(name: "variables", value: ProviderConstants.geminiGraphQLVariables)
        ]
        guard let url = comps.url else { return .transientFailure("URL 构造失败") }

        let req = makeCookieRequest(url: url, cookieHeader: cookieHeader, referer: "https://gemini.google.com/usage", timeout: 22)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .transientFailure("响应无效") }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .authExpired("Cookie 已过期 · 点击重新登录")
            }
            if http.url?.host?.contains("accounts.google.com") == true {
                return .authExpired("登录态已失效 · 点击重新登录")
            }
            guard http.statusCode == 200, var text = String(data: data, encoding: .utf8) else {
                return .transientFailure("HTTP \(http.statusCode)")
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix(")]}'") {
                text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let jsonData = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: jsonData)
            else {
                return .authExpired("登录态已失效 · 点击重新登录")
            }

            let envelopes = (parsed as? [[String: Any]]) ?? ((parsed as? [String: Any]).map { [$0] } ?? [])
            let dataObjects = envelopes.compactMap { $0["data"] as? [String: Any] }
            guard let viewerEnvelope = dataObjects.first(where: { $0.keys.contains("viewer") }) else {
                return .authExpired("登录已失效 · 点击重新登录")
            }
            if viewerEnvelope["viewer"] is NSNull {
                return .authExpired("登录已过期 · 点击重新登录")
            }
            guard let viewer = viewerEnvelope["viewer"] as? [String: Any],
                  let rpcs = viewer["rpcs"] as? [String: Any],
                  let usageInfo = rpcs["getUsageInfo"] as? [String: Any],
                  let pools = usageInfo["pools"] as? [[String: Any]]
            else {
                return .transientFailure("未解析到 Gemini 用量结构")
            }

            func parsePool(type: String, idx: Int, tag: String) -> QuotaWindowCandidate? {
                guard let pool = pools.first(where: { ($0["poolType"] as? String) == type }),
                      let rawUsed = HoverDataFetcher.doubleVal(pool["percentageUsed"]),
                      rawUsed >= 0
                else { return nil }
                let rem = 100.0 - min(100.0, rawUsed * 100.0)
                let resetDate = HoverDataFetcher.parseDate((pool["gxu"] as? [String: Any])?["windowRefreshesAt"])
                return QuotaWindowCandidate(idx: idx, tag: tag, remainingPercent: rem, resetDate: resetDate)
            }

            let wins = [
                parsePool(type: "GXU_FIVE_HOURLY", idx: 0, tag: "5h"),
                parsePool(type: "GXU_WEEKLY", idx: 1, tag: "周")
            ].compactMap { $0 }

            guard let item = buildConstrainedQuotaItem(id: "gemini", name: "Gemini", windows: wins) else {
                return .unconfigured("该账号暂无 Gemini 订阅窗口")
            }
            if let rotated = mergeSetCookies(response: http, currentCookieHeader: cookieHeader) {
                await AppPreferences.shared.updateRotatedCookieSilently(secretKey: "geminiCookie", newHeader: rotated)
            }
            return .success(item)
        } catch {
            return .transientFailure("请求超时 · 下周期重试")
        }
    }

    // MARK: - 3. Claude / Claude Code Quota

    static func fetchClaude(cookieInput: String, allowLocalOAuth: Bool = true) async -> FetchOutcome {
        let trimmed = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            let webRes = await fetchClaudeViaWebCookie(trimmed)
            if !allowLocalOAuth { return webRes }
            if case .success = webRes { return webRes }
            if case .transientFailure = webRes { return webRes }
        } else if !allowLocalOAuth {
            return .unconfigured("点击登录 Claude 账号")
        }

        if allowLocalOAuth {
            let localCredURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            if let credData = try? Data(contentsOf: localCredURL),
               let credObj = (try? JSONSerialization.jsonObject(with: credData)) as? [String: Any],
               let oauth = credObj["claudeAiOauth"] as? [String: Any],
               let accessToken = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !accessToken.isEmpty,
               let oauthURL = URL(string: "https://api.anthropic.com/api/oauth/usage")
            {
                var req = makeBearerRequest(url: oauthURL, token: accessToken, timeout: 18)
                req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                req.setValue(ProviderConstants.claudeCodeUserAgent, forHTTPHeaderField: "User-Agent")
                if let (uData, uResp) = try? await session.data(for: req),
                   (uResp as? HTTPURLResponse)?.statusCode == 200,
                   let root = (try? JSONSerialization.jsonObject(with: uData)) as? [String: Any],
                   case .success(let item) = parseClaudeUsageRoot(root)
                {
                    return .success(item)
                }
            }
        }

        return trimmed.isEmpty ? .unconfigured("点击登录 Claude 账号") : .authExpired("Claude 登录已过期")
    }

    private static func fetchClaudeViaWebCookie(_ trimmed: String) async -> FetchOutcome {
        guard let cookieHeader = AppPreferences.normalizedCookieHeader(from: trimmed),
              let orgsURL = URL(string: "https://claude.ai/api/organizations")
        else {
            return .unconfigured("点击重新登录账号")
        }

        let orgReq = makeCookieRequest(url: orgsURL, cookieHeader: cookieHeader)
        do {
            let (orgData, orgResp) = try await session.data(for: orgReq)
            guard let orgHTTP = orgResp as? HTTPURLResponse else { return .transientFailure("响应异常") }
            if orgHTTP.statusCode == 401 || orgHTTP.statusCode == 403 {
                return .authExpired("Claude 登录已过期")
            }
            guard orgHTTP.statusCode == 200,
                  let orgs = (try? JSONSerialization.jsonObject(with: orgData)) as? [[String: Any]],
                  let orgUUID = orgs.compactMap({ $0["uuid"] as? String }).first,
                  let usageURL = URL(string: "https://claude.ai/api/organizations/\(orgUUID)/usage")
            else {
                return .authExpired("无法读取 Claude 组织信息")
            }

            let uReq = makeCookieRequest(url: usageURL, cookieHeader: cookieHeader)
            let (uData, uResp) = try await session.data(for: uReq)
            guard let uHTTP = uResp as? HTTPURLResponse,
                  uHTTP.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: uData)) as? [String: Any]
            else {
                return .transientFailure("Claude 用量请求失败")
            }

            let outcome = parseClaudeUsageRoot(root)
            if case .success = outcome,
               let rotated = mergeSetCookies(response: uHTTP, currentCookieHeader: cookieHeader)
            {
                await AppPreferences.shared.updateRotatedCookieSilently(secretKey: "claudeCookie", newHeader: rotated)
            }
            return outcome
        } catch {
            return .transientFailure("请求超时 · 下周期重试")
        }
    }

    private static func parseClaudeUsageRoot(_ root: [String: Any]) -> FetchOutcome {
        func parseCl(_ key: String, idx: Int, tag: String) -> QuotaWindowCandidate? {
            guard let d = root[key] as? [String: Any],
                  let util = HoverDataFetcher.doubleVal(d["utilization"])
            else { return nil }
            return QuotaWindowCandidate(
                idx: idx,
                tag: tag,
                remainingPercent: 100.0 - util,
                resetDate: HoverDataFetcher.parseDate(d["resets_at"])
            )
        }
        let wins = [
            parseCl("five_hour", idx: 0, tag: "5h"),
            parseCl("seven_day", idx: 1, tag: "周")
        ].compactMap { $0 }

        guard let item = buildConstrainedQuotaItem(id: "claude", name: "Claude", windows: wins) else {
            return .unconfigured("暂无 Claude 配额数据")
        }
        return .success(item)
    }

    // MARK: - 4. DeepSeek Official API & Web Platform Balance

    static func fetchDeepSeekBalance(apiKey: String) async -> FetchOutcome {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: "https://api.deepseek.com/user/balance") else {
            return .unconfigured("填入 DeepSeek API Key")
        }
        do {
            let (data, resp) = try await session.data(for: makeBearerRequest(url: url, token: trimmed, timeout: 15))
            guard let http = resp as? HTTPURLResponse else { return .transientFailure("响应异常") }
            if http.statusCode == 401 || http.statusCode == 403 { return .authExpired("DeepSeek API Key 无效") }
            guard http.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let infos = root["balance_infos"] as? [[String: Any]],
                  let first = infos.first,
                  let total = HoverDataFetcher.doubleVal(first["total_balance"])
            else {
                return .transientFailure("余额解析失败")
            }
            let cur = (first["currency"] as? String) ?? "CNY"
            return .success(BalancePolicy.makeBalanceItem(
                id: "dsh",
                name: "DeepSeek",
                amount: total,
                currency: cur,
                subtitle: "API 余额 · 长期有效"
            ))
        } catch {
            return .transientFailure("请求超时")
        }
    }

    static func fetchDeepSeekWebBalance(userToken: String) async -> FetchOutcome {
        let trimmed = userToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: "https://platform.deepseek.com/api/v0/users/get_user_summary") else {
            return .unconfigured("点击登录 DeepSeek")
        }
        var req = makeBearerRequest(url: url, token: trimmed, timeout: 15)
        req.setValue(trimmed, forHTTPHeaderField: "x-dsh-auth-token")
        req.setValue(ProviderConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .transientFailure("响应异常") }
            if http.statusCode == 401 || http.statusCode == 403 { return .authExpired("DeepSeek 登录已过期") }
            guard http.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let dataObj = root["data"] as? [String: Any],
                  let biz = dataObj["biz_data"] as? [String: Any]
            else {
                return .transientFailure("余额读取异常")
            }

            var cnyTotal: Double?
            var usdTotal: Double?
            let wallets = ((biz["normal_wallets"] as? [[String: Any]]) ?? []) + ((biz["bonus_wallets"] as? [[String: Any]]) ?? [])
            for w in wallets {
                guard let cur = w["currency"] as? String,
                      let bal = HoverDataFetcher.doubleVal(w["balance"])
                else { continue }
                if cur == "CNY" { cnyTotal = (cnyTotal ?? 0) + bal }
                if cur == "USD" { usdTotal = (usdTotal ?? 0) + bal }
            }

            if let cny = cnyTotal {
                return .success(BalancePolicy.makeBalanceItem(
                    id: "dsh",
                    name: "DeepSeek",
                    amount: cny,
                    currency: "CNY",
                    subtitle: "平台总余额 · 长期有效"
                ))
            }
            if let usd = usdTotal {
                return .success(BalancePolicy.makeBalanceItem(
                    id: "dsh",
                    name: "DeepSeek",
                    amount: usd,
                    currency: "USD",
                    subtitle: "平台总余额 · 长期有效"
                ))
            }
            return .unconfigured("账号暂无可用余额记录")
        } catch {
            return .transientFailure("请求超时")
        }
    }

    // MARK: - 5. Tencent WorkBuddy / CodeBuddy

    static func fetchWorkBuddy(authInput: String) async -> FetchOutcome {
        let envTok = ProcessInfo.processInfo.environment["CODEBUDDY_AUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmed = authInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeRaw = !trimmed.isEmpty ? trimmed : (envTok.isEmpty ? "" : "Bearer \(envTok)")
        guard !activeRaw.isEmpty else { return .unconfigured("点击登录 WorkBuddy") }

        var scopedDomain: String?
        var bearerToken: String?
        var cookieHeader: String?

        if activeRaw.contains("||") {
            for seg in activeRaw.components(separatedBy: "||") {
                let s = seg.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.lowercased().hasPrefix("domain=") {
                    scopedDomain = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces).lowercased()
                } else if s.lowercased().hasPrefix("bearer ") {
                    bearerToken = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                } else if let ck = AppPreferences.normalizedCookieHeader(from: s) {
                    cookieHeader = ck
                } else if !s.isEmpty {
                    bearerToken = s
                }
            }
        } else if activeRaw.lowercased().hasPrefix("bearer ") {
            bearerToken = String(activeRaw.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        } else if let ck = AppPreferences.normalizedCookieHeader(from: activeRaw) {
            cookieHeader = ck
        } else {
            bearerToken = activeRaw
        }

        let allEndpoints: [(url: String, domain: String)] = [
            ("https://www.codebuddy.cn/billing/meter/get-user-resource-summary", "codebuddy.cn"),
            ("https://www.workbuddy.cn/billing/meter/get-user-resource-summary", "workbuddy.cn"),
            ("https://www.codebuddy.cn/ai/v2/billing/meter/get-user-resource", "codebuddy.cn"),
            ("https://www.workbuddy.ai/ai/v2/billing/meter/get-user-resource", "workbuddy.ai")
        ]
        let endpoints: [(url: String, domain: String)]
        if let sd = scopedDomain, !sd.isEmpty {
            endpoints = allEndpoints.filter { $0.domain == sd }
        } else if cookieHeader != nil {
            endpoints = allEndpoints.filter { $0.domain == "codebuddy.cn" }
        } else {
            endpoints = allEndpoints
        }

        var sawUnauthorized = false
        for ep in endpoints {
            guard let url = URL(string: ep.url) else { continue }
            var req = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 18)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(ep.domain, forHTTPHeaderField: "X-Domain")
            req.setValue("https://www.\(ep.domain)/profile", forHTTPHeaderField: "Referer")
            req.setValue(ProviderConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
            if let tok = bearerToken, !tok.isEmpty { req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization") }
            if let ck = cookieHeader, !ck.isEmpty {
                req.setValue(ck, forHTTPHeaderField: "Cookie")
                req.httpShouldHandleCookies = false
            }
            req.httpBody = Data("{}".utf8)

            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse
            else { continue }

            if http.statusCode == 401 || http.statusCode == 403 {
                sawUnauthorized = true
                continue
            }
            guard http.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            if let code = HoverDataFetcher.safeInt(root["code"]), code != 0 && code != 200 {
                if code == 401 || code == 403 || code == 1001 { sawUnauthorized = true }
                continue
            }

            let inner = (root["data"] as? [String: Any]) ?? (root["result"] as? [String: Any]) ?? root
            let pkgs = (inner["Packages"] as? [[String: Any]]) ?? (inner["packages"] as? [[String: Any]]) ?? []

            var pkgTotal = 0.0
            var pkgRem = 0.0
            var earliestReset: Date?

            for p in pkgs {
                let cap = HoverDataFetcher.doubleVal(p["CycleTotalCapacity"] ?? p["total"] ?? p["TotalCapacity"]) ?? 0
                let rem = HoverDataFetcher.doubleVal(p["CycleRemainCapacity"] ?? p["remaining"] ?? p["RemainCapacity"])
                let used = HoverDataFetcher.doubleVal(p["CycleUsedCapacity"] ?? p["used"])
                if cap > 0 {
                    pkgTotal += cap
                    pkgRem += rem ?? max(0, cap - (used ?? 0))
                }
                if let exp = HoverDataFetcher.parseDate(p["ExpireTime"] ?? p["expireTime"] ?? p["CycleEndTime"]),
                   exp > Date(), earliestReset == nil || exp < earliestReset!
                {
                    earliestReset = exp
                }
            }

            let topRem = HoverDataFetcher.doubleVal(inner["remainingCredits"] ?? inner["TotalCredits"] ?? inner["RemainCredits"])
            let topTotal = HoverDataFetcher.doubleVal(inner["totalCredits"] ?? inner["TotalCapacity"])
            let finalTotal = pkgTotal > 0 ? pkgTotal : (topTotal ?? 0)
            let finalRem = pkgTotal > 0 ? pkgRem : (topRem ?? -1)

            if finalTotal > 0 && finalRem >= 0 {
                let pct = min(100, max(0, (finalRem / finalTotal) * 100.0))
                return .success(QuotaItem(
                    id: "workbuddy",
                    name: "WorkBuddy",
                    kind: "quota",
                    windowLabel: "积分",
                    remainingPercent: pct,
                    remainingText: "\(Int(pct.rounded()))%",
                    subText: "余 \(HoverDataFetcher.formatInt(finalRem))",
                    resetsAt: earliestReset,
                    status: HoverDataFetcher.statusFor(pct)
                ))
            } else if let remOnly = topRem, remOnly >= 0 {
                let pct = remOnly > 0 ? 100.0 : 0.0
                return .success(QuotaItem(
                    id: "workbuddy",
                    name: "WorkBuddy",
                    kind: "quota",
                    windowLabel: "积分",
                    remainingPercent: pct,
                    remainingText: HoverDataFetcher.formatInt(remOnly),
                    subText: "可用积分",
                    resetsAt: earliestReset,
                    status: remOnly <= 0 ? "critical" : (remOnly < 50 ? "warning" : "ok")
                ))
            }
        }

        return sawUnauthorized ? .authExpired("登录已过期 · 点击重新登录") : .transientFailure("未能读取 WorkBuddy 积分")
    }

    // MARK: - 6. Cursor Web Quota

    static func fetchCursor(cookieInput: String) async -> FetchOutcome {
        let trimmed = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unconfigured("点击登录 Cursor 账号") }
        let rawNormalized = (!trimmed.contains("=") && trimmed.count > 16)
            ? "WorkosCursorSessionToken=\(trimmed)"
            : trimmed
        guard let cookieHeader = AppPreferences.normalizedCookieHeader(from: rawNormalized) else {
            return .unconfigured("点击重新登录 Cursor")
        }

        for endpoint in ["https://cursor.com/api/usage-summary", "https://www.cursor.com/api/usage-summary"] {
            guard let url = URL(string: endpoint) else { continue }
            var req = makeCookieRequest(url: url, cookieHeader: cookieHeader, referer: "https://cursor.com/dashboard")
            req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")

            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse
            else { continue }

            if http.statusCode == 401 || http.statusCode == 403 {
                return .authExpired("Cursor 登录已过期")
            }
            guard http.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            if let rotated = mergeSetCookies(response: http, currentCookieHeader: cookieHeader) {
                await AppPreferences.shared.updateRotatedCookieSilently(secretKey: "cursorCookie", newHeader: rotated)
            }
            let resetDate = HoverDataFetcher.parseDate(root["billingCycleEnd"])
            let tier = ((root["membershipType"] as? String) ?? "月").uppercased()
            if (root["isUnlimited"] as? Bool) == true {
                return .success(QuotaItem(
                    id: "cursor",
                    name: "Cursor",
                    kind: "quota",
                    windowLabel: tier,
                    remainingPercent: 100,
                    remainingText: "无限",
                    subText: "不限速套餐",
                    resetsAt: resetDate,
                    status: "ok"
                ))
            }
            if let ind = root["individualUsage"] as? [String: Any],
               let plan = ind["plan"] as? [String: Any]
            {
                var remPct = HoverDataFetcher.doubleVal(plan["totalPercentUsed"]).map { min(100, max(0, 100.0 - $0)) }
                var sub: String?
                if let limit = HoverDataFetcher.doubleVal(plan["limit"]), limit > 0,
                   let used = HoverDataFetcher.doubleVal(plan["used"])
                {
                    let remVal = HoverDataFetcher.doubleVal(plan["remaining"]) ?? max(0, limit - used)
                    if remPct == nil { remPct = min(100, max(0, (remVal / limit) * 100.0)) }
                    sub = limit >= 500
                        ? String(format: "余 $%.1f/$%.0f", remVal / 100.0, limit / 100.0)
                        : "余 \(HoverDataFetcher.formatInt(remVal))/\(HoverDataFetcher.formatInt(limit))"
                }
                if let pct = remPct {
                    return .success(QuotaItem(
                        id: "cursor",
                        name: "Cursor",
                        kind: "quota",
                        windowLabel: "月",
                        remainingPercent: pct,
                        remainingText: "\(Int(pct.rounded()))%",
                        subText: sub ?? tier,
                        resetsAt: resetDate,
                        status: HoverDataFetcher.statusFor(pct)
                    ))
                }
            }
        }

        if let legacyURL = URL(string: "https://cursor.com/api/usage"),
           let (data, resp) = try? await session.data(for: makeCookieRequest(url: legacyURL, cookieHeader: cookieHeader, referer: "https://cursor.com/dashboard")),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let gpt4 = root["gpt-4"] as? [String: Any],
           let used = HoverDataFetcher.doubleVal(gpt4["numRequests"]),
           let limit = HoverDataFetcher.doubleVal(gpt4["maxRequestUsage"]),
           limit > 0
        {
            let rem = max(0, limit - used)
            let pct = min(100, max(0, (rem / limit) * 100.0))
            return .success(QuotaItem(
                id: "cursor",
                name: "Cursor",
                kind: "quota",
                windowLabel: "月",
                remainingPercent: pct,
                remainingText: "\(Int(pct.rounded()))%",
                subText: "余 \(HoverDataFetcher.formatInt(rem))/\(HoverDataFetcher.formatInt(limit))",
                resetsAt: nil,
                status: HoverDataFetcher.statusFor(pct)
            ))
        }
        return .transientFailure("未能读取 Cursor 额度")
    }

    // MARK: - 7. GitHub Copilot

    static func discoverLocalCopilotToken() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let jsonCandidates = [
            home.appendingPathComponent("Library/Application Support/github-copilot/hosts.json"),
            home.appendingPathComponent("Library/Application Support/github-copilot/apps.json"),
            home.appendingPathComponent(".config/github-copilot/hosts.json"),
            home.appendingPathComponent(".config/github-copilot/apps.json")
        ]
        for fileURL in jsonCandidates {
            guard let data = try? Data(contentsOf: fileURL),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            for (_, entryAny) in dict {
                if let entry = entryAny as? [String: Any],
                   let tok = (entry["oauth_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !tok.isEmpty
                {
                    return tok
                }
            }
        }
        let ghHostsURL = home.appendingPathComponent(".config/gh/hosts.yml")
        if let yml = try? String(contentsOf: ghHostsURL, encoding: .utf8) {
            for line in yml.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("oauth_token:") {
                    let tok = String(t.dropFirst("oauth_token:".count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !tok.isEmpty { return tok }
                }
            }
        }
        return nil
    }

    static var hasGHCLIInstalled: Bool {
        ProviderConstants.findExecutable("gh") != nil
    }

    static func fetchGHCLIToken() async -> String? {
        guard let ghPath = ProviderConstants.findExecutable("gh") else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ghPath)
                proc.arguments = ["auth", "token"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    guard proc.terminationStatus == 0 else {
                        cont.resume(returning: nil)
                        return
                    }
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(returning: (out?.isEmpty == false) ? out : nil)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    static func fetchCopilot(savedToken: String) async -> FetchOutcome {
        let manual = savedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeToken = !manual.isEmpty ? manual : (discoverLocalCopilotToken() ?? "")
        guard !activeToken.isEmpty else {
            return hasGHCLIInstalled ? .unconfigured("检测到 gh CLI · 点击一键连接") : .unconfigured("填入 GitHub Token 或登录 IDE")
        }
        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
            return .transientFailure("URL 错误")
        }

        var req = makeBearerRequest(url: url, token: activeToken, timeout: 18)
        req.setValue(ProviderConstants.copilotEditorVersion, forHTTPHeaderField: "Editor-Version")
        req.setValue(ProviderConstants.copilotPluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
        req.setValue(ProviderConstants.copilotUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .transientFailure("响应异常") }
            if http.statusCode == 401 { return .authExpired("GitHub Token 无效或已过期") }
            if http.statusCode == 403 {
                let rlRem = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
                let bodyText = (String(data: data, encoding: .utf8) ?? "").lowercased()
                if rlRem == "0" || bodyText.contains("rate limit") || bodyText.contains("abuse") {
                    return .transientFailure("GitHub 接口限流 · 稍后重试")
                }
                return .authExpired("无 Copilot 权限或 Token 失效")
            }
            if http.statusCode == 429 { return .transientFailure("GitHub 接口限流 · 稍后重试") }
            guard http.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                return .transientFailure("Copilot HTTP \(http.statusCode)")
            }

            let resetDate = HoverDataFetcher.parseDate(root["quota_reset_date_utc"] ?? root["quota_reset_date"])
            if let snaps = root["quota_snapshots"] as? [String: Any],
               let prem = snaps["premium_interactions"] as? [String: Any]
            {
                if (prem["unlimited"] as? Bool) == true {
                    return .success(QuotaItem(
                        id: "copilot",
                        name: "Copilot",
                        kind: "quota",
                        windowLabel: "月",
                        remainingPercent: 100,
                        remainingText: "无限",
                        subText: "无限高级请求",
                        resetsAt: resetDate,
                        status: "ok"
                    ))
                }
                let remOpt = HoverDataFetcher.doubleVal(prem["remaining"])
                let entOpt = HoverDataFetcher.doubleVal(prem["entitlement"])
                let pctOpt = HoverDataFetcher.doubleVal(prem["percent_remaining"])
                if let pctVal = pctOpt ?? ((remOpt != nil && (entOpt ?? 0) > 0) ? (remOpt! / entOpt!) * 100.0 : nil) {
                    let clamped = min(100, max(0, pctVal))
                    let subStr = (remOpt != nil && (entOpt ?? 0) > 0)
                        ? "余 \(HoverDataFetcher.formatInt(remOpt!))/\(HoverDataFetcher.formatInt(entOpt!))"
                        : "高级请求"
                    return .success(QuotaItem(
                        id: "copilot",
                        name: "Copilot",
                        kind: "quota",
                        windowLabel: "月",
                        remainingPercent: clamped,
                        remainingText: "\(Int(clamped.rounded()))%",
                        subText: subStr,
                        resetsAt: resetDate,
                        status: HoverDataFetcher.statusFor(clamped)
                    ))
                }
            }
            guard let plan = root["copilot_plan"] as? String, !plan.isEmpty else {
                return .transientFailure("未解析到 Copilot 配额字段")
            }
            return .success(QuotaItem(
                id: "copilot",
                name: "Copilot",
                kind: "quota",
                windowLabel: "订阅",
                remainingPercent: 100,
                remainingText: "已激活",
                subText: plan.capitalized,
                resetsAt: resetDate,
                status: "ok"
            ))
        } catch {
            return .transientFailure("请求超时")
        }
    }

    // MARK: - 8. 智谱 GLM Coding Plan

    static func fetchGLM(apiKey: String) async -> FetchOutcome {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit") else {
            return .unconfigured("填入智谱 API Key")
        }
        do {
            let (data, resp) = try await session.data(for: makeBearerRequest(url: url, token: trimmed))
            guard let http = resp as? HTTPURLResponse else { return .transientFailure("响应异常") }
            if http.statusCode == 401 || http.statusCode == 403 { return .authExpired("智谱 API Key 无效") }
            if http.statusCode == 429 || http.statusCode >= 500 { return .transientFailure("GLM HTTP \(http.statusCode)") }
            guard http.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                return .transientFailure("GLM HTTP \(http.statusCode)")
            }
            if let code = HoverDataFetcher.safeInt(root["code"]), code != 200 && code != 0 {
                let msg = (root["msg"] as? String) ?? "智谱接口异常 (\(code))"
                return (code == 401 || code == 403 || code == 1001 || code == 1002)
                    ? .authExpired(msg)
                    : .transientFailure(msg)
            }
            guard let dataObj = root["data"] as? [String: Any],
                  let limits = dataObj["limits"] as? [[String: Any]],
                  !limits.isEmpty
            else {
                return .unconfigured("该 Key 未开通 GLM Coding Plan")
            }

            var wins: [QuotaWindowCandidate] = []
            for (idx, lim) in limits.enumerated() {
                let typeStr = (lim["type"] as? String) ?? ""
                if typeStr == "TIME_LIMIT" && limits.contains(where: { ($0["type"] as? String) != "TIME_LIMIT" }) {
                    continue
                }
                guard let usedPct = HoverDataFetcher.doubleVal(lim["percentage"]) else { continue }
                let unit = HoverDataFetcher.safeInt(lim["unit"]) ?? 3
                let num = max(1, min(720, HoverDataFetcher.safeInt(lim["number"]) ?? 5))
                let tag: String
                switch unit {
                case 3: tag = "\(num)h"
                case 6: tag = "周"
                case 5: tag = "月"
                default: tag = "周期"
                }
                wins.append(QuotaWindowCandidate(
                    idx: idx,
                    tag: tag,
                    remainingPercent: 100.0 - usedPct,
                    resetDate: HoverDataFetcher.parseDate(lim["nextResetTime"])
                ))
            }

            guard let item = buildConstrainedQuotaItem(id: "glm", name: "智谱 GLM", windows: wins) else {
                return .unconfigured("未解析到 GLM 窗口配额")
            }
            return .success(item)
        } catch {
            return .transientFailure("请求超时")
        }
    }

    // MARK: - 9. MiniMax Coding Plan

    static func fetchMiniMax(apiKey: String) async -> FetchOutcome {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unconfigured("填入 MiniMax Coding Key") }

        let endpoints = [
            "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains",
            "https://api.minimax.io/v1/api/openplatform/coding_plan/remains"
        ]
        var sawAuthFailure = false
        var sawUnconfigured = false

        for endpoint in endpoints {
            guard let url = URL(string: endpoint),
                  let (data, resp) = try? await session.data(for: makeBearerRequest(url: url, token: trimmed)),
                  let http = resp as? HTTPURLResponse
            else { continue }

            if http.statusCode == 401 || http.statusCode == 403 {
                sawAuthFailure = true
                continue
            }
            guard http.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }

            if let baseResp = root["base_resp"] as? [String: Any],
               let code = HoverDataFetcher.safeInt(baseResp["status_code"]),
               code != 0
            {
                if code == 1004 || code == 1002 || code == 401 || code == 403 { sawAuthFailure = true }
                continue
            }

            let dataScope = (root["data"] as? [String: Any]) ?? root
            let remains = (dataScope["model_remains"] as? [[String: Any]]) ?? (root["model_remains"] as? [[String: Any]]) ?? []
            let target = remains.first(where: { ($0["model_name"] as? String) == "general" }) ?? remains.first ?? dataScope

            // Note: MiniMax `/coding_plan/remains` `current_interval_usage_count` represents REMAINING count!
            var rem5h = HoverDataFetcher.doubleVal(target["current_interval_remaining_percent"] ?? dataScope["current_interval_remaining_percent"])
            if rem5h == nil,
               let remCnt = HoverDataFetcher.doubleVal(target["current_interval_usage_count"] ?? dataScope["current_interval_usage_count"] ?? target["remains"]),
               let totCnt = HoverDataFetcher.doubleVal(target["current_interval_total_count"] ?? dataScope["current_interval_total_count"] ?? target["total"]),
               totCnt > 0
            {
                rem5h = (remCnt / totCnt) * 100.0
            }

            var remWeek = HoverDataFetcher.doubleVal(target["current_weekly_remaining_percent"] ?? dataScope["current_weekly_remaining_percent"])
            if remWeek == nil,
               let wRemCnt = HoverDataFetcher.doubleVal(target["current_weekly_usage_count"] ?? dataScope["current_weekly_usage_count"]),
               let wTotCnt = HoverDataFetcher.doubleVal(target["current_weekly_total_count"] ?? dataScope["current_weekly_total_count"]),
               wTotCnt > 0
            {
                remWeek = (wRemCnt / wTotCnt) * 100.0
            }

            let resetDate: Date? = {
                if let msLeft = HoverDataFetcher.doubleVal(target["remains_time"] ?? dataScope["remains_time"]), msLeft > 0 {
                    return Date().addingTimeInterval(msLeft / 1000.0)
                }
                return HoverDataFetcher.parseDate(
                    target["end_time"] ?? target["current_interval_reset_time"] ?? dataScope["current_interval_reset_time"]
                )
            }()

            var wins: [QuotaWindowCandidate] = []
            if let r5 = rem5h { wins.append(QuotaWindowCandidate(idx: 0, tag: "5h", remainingPercent: r5, resetDate: resetDate)) }
            if let rw = remWeek { wins.append(QuotaWindowCandidate(idx: 1, tag: "周", remainingPercent: rw, resetDate: resetDate)) }

            guard let item = buildConstrainedQuotaItem(id: "minimax", name: "MiniMax", windows: wins) else {
                sawUnconfigured = true
                continue
            }
            return .success(item)
        }

        if sawAuthFailure { return .authExpired("MiniMax Key 无效或未开通套餐") }
        if sawUnconfigured { return .unconfigured("该 Key 未查到套餐余量") }
        return .transientFailure("MiniMax 请求超时")
    }

    // MARK: - 10. Kimi / Kimi Code (Dual-Mode)

    static func fetchKimi(apiKey: String) async -> FetchOutcome {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unconfigured("填入 Kimi / Moonshot Key") }

        var codingTransientError = false
        if let codeURL = URL(string: "https://api.kimi.com/coding/v1/usages") {
            do {
                let (data, resp) = try await session.data(for: makeBearerRequest(url: codeURL, token: trimmed, timeout: 15))
                if let http = resp as? HTTPURLResponse {
                    if http.statusCode == 429 || http.statusCode >= 500 {
                        codingTransientError = true
                    } else if http.statusCode == 200,
                              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    {
                        var wins: [QuotaWindowCandidate] = []
                        if let usage = root["usage"] as? [String: Any],
                           let lim = HoverDataFetcher.doubleVal(usage["limit"]), lim > 0,
                           let rem = HoverDataFetcher.doubleVal(usage["remaining"])
                        {
                            wins.append(QuotaWindowCandidate(
                                idx: 0,
                                tag: "周",
                                remainingPercent: (rem / lim) * 100.0,
                                resetDate: HoverDataFetcher.parseDate(usage["resetTime"])
                            ))
                        }
                        if let limArr = root["limits"] as? [[String: Any]] {
                            for (offset, entry) in limArr.enumerated() {
                                guard let detail = entry["detail"] as? [String: Any],
                                      let lim = HoverDataFetcher.doubleVal(detail["limit"]), lim > 0,
                                      let rem = HoverDataFetcher.doubleVal(detail["remaining"])
                                else { continue }
                                let mins = HoverDataFetcher.safeInt((entry["window"] as? [String: Any])?["duration"])
                                wins.append(QuotaWindowCandidate(
                                    idx: offset + 1,
                                    tag: HoverDataFetcher.windowTag(minutes: mins),
                                    remainingPercent: (rem / lim) * 100.0,
                                    resetDate: HoverDataFetcher.parseDate(detail["resetTime"])
                                ))
                            }
                        }
                        if let item = buildConstrainedQuotaItem(id: "kimi", name: "Kimi Code", windows: wins) {
                            return .success(item)
                        }
                    }
                }
            } catch {
                codingTransientError = true
            }
        }

        guard let balURL = URL(string: "https://api.moonshot.cn/v1/users/me/balance") else {
            return .transientFailure("URL 错误")
        }
        do {
            let (data, resp) = try await session.data(for: makeBearerRequest(url: balURL, token: trimmed, timeout: 15))
            guard let http = resp as? HTTPURLResponse else { return .transientFailure("响应异常") }
            if http.statusCode == 401 || http.statusCode == 403 {
                return codingTransientError ? .transientFailure("Kimi Code 请求超时 · 稍后重试") : .authExpired("Kimi / Moonshot Key 无效")
            }
            guard http.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let inner = root["data"] as? [String: Any],
                  let bal = HoverDataFetcher.doubleVal(inner["available_balance"])
            else {
                return .transientFailure("余额解析失败")
            }
            return .success(BalancePolicy.makeBalanceItem(
                id: "kimi",
                name: "Kimi",
                amount: bal,
                currency: "CNY",
                subtitle: "Moonshot 余额 · 长期有效"
            ))
        } catch {
            return .transientFailure("请求超时")
        }
    }

    // MARK: - 11. 豆包 / 火山方舟 Agent & Coding Plan

    static func fetchVolcArkPlan(akskInput: String) async -> FetchOutcome {
        let trimmed = akskInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unconfigured("填入火山 AK:SK") }
        let parts = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ":|, \t\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return .unconfigured("格式需为 AK:SK") }
        let ak = parts[0], sk = parts[1]

        var seatID: String?
        for scene in ["", "coding_plan_enterprise", "coding_plan"] {
            let bodyDict: [String: Any] = scene.isEmpty ? [:] : ["Scene": scene]
            guard let lCall = await callVolcArkOpenAPI(action: "ListSeatInfos", bodyObj: bodyDict, ak: ak, sk: sk) else { continue }
            if lCall.status == 401 || lCall.status == 403 { return .authExpired("火山 AK/SK 无权限或已失效") }
            if let err = (lCall.root["ResponseMetadata"] as? [String: Any])?["Error"] as? [String: Any],
               let code = (err["Code"] as? String)?.lowercased(),
               code.contains("signature") || code.contains("auth") || code.contains("accesskey")
            {
                return .authExpired("火山 AK/SK 校验失败")
            }
            if let result = lCall.root["Result"] as? [String: Any] {
                let list = (result["Items"] as? [[String: Any]])
                    ?? (result["SeatInfos"] as? [[String: Any]])
                    ?? (result["List"] as? [[String: Any]])
                    ?? []
                if let firstID = list.compactMap({ $0["SeatID"] as? String }).first, !firstID.isEmpty {
                    seatID = firstID
                    break
                }
            }
        }

        var usagePayload: [String: Any] = [:]
        if let sid = seatID { usagePayload["SeatID"] = sid }
        guard let uCall = await callVolcArkOpenAPI(action: "GetSeatInfoUsage", bodyObj: usagePayload, ak: ak, sk: sk) else {
            return .transientFailure("请求火山方舟超时")
        }
        if uCall.status == 401 || uCall.status == 403 { return .authExpired("火山 AK/SK 无权限或已失效") }
        if uCall.status == 429 || uCall.status >= 500 { return .transientFailure("火山方舟 HTTP \(uCall.status)") }

        if let err = (uCall.root["ResponseMetadata"] as? [String: Any])?["Error"] as? [String: Any] {
            let code = ((err["Code"] as? String) ?? "").lowercased()
            let msg = String(((err["Message"] as? String) ?? "方舟接口异常").prefix(24))
            if code.contains("signature") || code.contains("auth") || code.contains("accesskey") || code.contains("denied") {
                return .authExpired(msg)
            }
            if code.contains("limit") || code.contains("throttl") || code.contains("internal") {
                return .transientFailure(msg)
            }
            return .unconfigured(msg)
        }
        guard let res = uCall.root["Result"] as? [String: Any] else {
            return .unconfigured("未查到方舟套餐席位")
        }

        var wins: [QuotaWindowCandidate] = []
        if let st = HoverDataFetcher.doubleVal(res["ShortTermUsage"]) {
            wins.append(QuotaWindowCandidate(idx: 0, tag: "5h", remainingPercent: 100.0 - st, resetDate: HoverDataFetcher.parseDate(res["ShortTermResetMilestone"])))
        }
        if let wk = HoverDataFetcher.doubleVal(res["WeeklyUsage"]) {
            wins.append(QuotaWindowCandidate(idx: 1, tag: "周", remainingPercent: 100.0 - wk, resetDate: HoverDataFetcher.parseDate(res["WeeklyResetMilestone"])))
        }
        if let mo = HoverDataFetcher.doubleVal(res["MonthlyUsage"]) {
            wins.append(QuotaWindowCandidate(idx: 2, tag: "月", remainingPercent: 100.0 - mo, resetDate: HoverDataFetcher.parseDate(res["MonthlyResetMilestone"])))
        }

        guard let item = buildConstrainedQuotaItem(id: "volcark", name: "豆包/方舟", windows: wins) else {
            return .unconfigured("暂无方舟席位用量数据")
        }
        return .success(item)
    }

    private static func callVolcArkOpenAPI(
        action: String,
        bodyObj: [String: Any],
        ak: String,
        sk: String
    ) async -> (status: Int, root: [String: Any])? {
        let host = ProviderConstants.volcArkHost
        let region = ProviderConstants.volcArkRegion
        let service = ProviderConstants.volcArkService
        let query = "Action=\(action)&Version=\(ProviderConstants.volcArkVersion)"
        guard let url = URL(string: "https://\(host)/?\(query)"),
              let bodyData = try? JSONSerialization.data(withJSONObject: bodyObj)
        else { return nil }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let xDate = fmt.string(from: Date())
        let shortDate = String(xDate.prefix(8))

        func sha256Hex(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func hmac(_ key: Data, _ msg: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
        }

        let contentType = "application/json; charset=utf-8"
        let bodyHash = sha256Hex(bodyData)
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\nx-content-sha256:\(bodyHash)\nx-date:\(xDate)\n"
        let canonicalRequest = "POST\n/\n\(query)\n\(canonicalHeaders)\n\(signedHeaders)\n\(bodyHash)"
        let credScope = "\(shortDate)/\(region)/\(service)/request"
        let stringToSign = "HMAC-SHA256\n\(xDate)\n\(credScope)\n\(sha256Hex(Data(canonicalRequest.utf8)))"

        let kDate = hmac(Data(sk.utf8), shortDate)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        let kSigning = hmac(kService, "request")
        let signature = hmac(kSigning, stringToSign).map { String(format: "%02x", $0) }.joined()
        let authHeader = "HMAC-SHA256 Credential=\(ak)/\(credScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(xDate, forHTTPHeaderField: "X-Date")
        req.setValue(bodyHash, forHTTPHeaderField: "X-Content-Sha256")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = bodyData

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return nil }
        let root = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        return (http.statusCode, root)
    }

    // MARK: - Cookie Rotation Merger

    private static func mergeSetCookies(response: HTTPURLResponse, currentCookieHeader: String) -> String? {
        guard let url = response.url else { return nil }
        var headers: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { headers[ks] = vs }
        }
        let incoming = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard !incoming.isEmpty else { return nil }

        var order: [String] = []
        var map: [String: String] = [:]
        for pair in currentCookieHeader.components(separatedBy: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let k = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { continue }
            if map[k] == nil { order.append(k) }
            map[k] = v
        }

        var changed = false
        let now = Date()
        for c in incoming {
            if let exp = c.expiresDate, exp <= now { continue }
            guard !c.name.isEmpty, !c.value.isEmpty, map[c.name] != c.value else { continue }
            if map[c.name] == nil { order.append(c.name) }
            map[c.name] = c.value
            changed = true
        }
        guard changed else { return nil }
        return order.compactMap { k in map[k].map { "\(k)=\($0)" } }.joined(separator: "; ")
    }
}
