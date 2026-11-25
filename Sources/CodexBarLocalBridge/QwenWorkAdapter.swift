import Foundation

public enum QwenWorkAdapter {
    public static let bundleIdentifiers = [
        "com.qwenwork.cn"
    ]

    static var authCandidateFiles: [URL] {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return [
            appSupport.appendingPathComponent("QwenWorkCN/auth-v2.dat"),
            appSupport.appendingPathComponent("QwenWorkCN/auth.dat"),
            appSupport.appendingPathComponent("QoderWork/auth-v2.dat")
        ]
    }

    static let keychainServices = [
        "QwenWorkCN Safe Storage",
        "QwenWork Safe Storage",
        "qwen-work-cn Safe Storage",
        "QoderWork Safe Storage"
    ]

    public static func checkStatus(interactive: Bool = false) -> (state: String, account: String?) {
        let res = SafeStorageReader.shared.decryptFile(
            candidateFiles: authCandidateFiles,
            candidateServices: keychainServices,
            interactive: interactive
        )
        guard res.state == "available" else {
            return (res.state, nil)
        }
        guard let plain = res.plaintext,
              let root = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              JSONUtil.string(root["token"] ?? root["accessToken"]) != nil
        else {
            return ("invalid", nil)
        }
        let user = root["user"] as? [String: Any]
        let label = JSONUtil.string(user?["name"] ?? user?["nickname"] ?? user?["email"] ?? user?["mobile"] ?? user?["id"])
        return ("available", label)
    }

    public static func fetchSnapshot() async throws -> DesktopQuotaSnapshot {
        let res = SafeStorageReader.shared.decryptFile(
            candidateFiles: authCandidateFiles,
            candidateServices: keychainServices,
            interactive: false
        )
        switch res.state {
        case "needs_authorization":
            throw BridgeError.needsAuthorization("本机已就绪 · 授权一次即可")
        case "missing":
            throw BridgeError.notConfigured("未检测到千问Work登录态")
        default:
            break
        }

        guard let plain = res.plaintext,
              let authRoot = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              let token = JSONUtil.string(authRoot["token"] ?? authRoot["accessToken"])
        else {
            throw BridgeError.parse("无法解析千问Work登录数据")
        }

        let authUser = authRoot["user"] as? [String: Any]
        let isBiz = (authUser?["isBiz"] as? Bool) ?? (authUser?["is_biz"] as? Bool) ?? false
        let endpoints = authRoot["endpoints"] as? [String: Any]
        let apiOrigin = JSONUtil.string(endpoints?["apiOrigin"] ?? authRoot["openApiBase"])
            ?? "https://gateway.qwenwork.cn"

        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": AdapterConstants.qwenWorkUserAgent,
            "X-QwenWork-Version": AdapterConstants.qwenWorkVersion,
            "X-QwenWork-Platform": "darwin",
            "X-QwenWork-Arch": "arm64",
            "X-QwenWork-Language": "zh-CN",
            "X-Request-Id": UUID().uuidString
        ]

        let contextPaths = [
            "/user/v2/account-context?include=user,plan,quota,page,data_sharing",
            "/api/v1/adapter/user/account-context?include=user,plan,quota,page,data_sharing",
            "/user/v2/quota",
            "/api/v2/quota/usage"
        ]

        var contextData: [String: Any]?
        var lastStatus = 0
        for path in contextPaths {
            if let r = try? await AsyncHTTP.getJSON(url: "\(apiOrigin)\(path)", headers: headers, timeout: 14) {
                lastStatus = r.status
                if r.status == 200, let obj = r.json {
                    let unwrapped = JSONUtil.unwrap(obj)
                    if unwrapped["quota"] != nil || unwrapped["user_quota"] != nil || unwrapped["userQuota"] != nil || unwrapped["remaining"] != nil {
                        contextData = unwrapped
                        break
                    }
                }
            }
        }

        var balanceData: [String: Any]?
        var walletsData: [String: Any]?
        if contextData == nil {
            for bPath in ["/user/balance", "/api/v1/adapter/user/balance"] {
                if let r = try? await AsyncHTTP.getJSON(url: "\(apiOrigin)\(bPath)", headers: headers, timeout: 10),
                   r.status == 200, let obj = r.json
                {
                    balanceData = JSONUtil.unwrap(obj)
                    break
                }
            }
            for wPath in ["/user/wallets", "/api/v1/adapter/user/wallets"] {
                if let r = try? await AsyncHTTP.getJSON(url: "\(apiOrigin)\(wPath)", headers: headers, timeout: 10),
                   r.status == 200, let obj = r.json
                {
                    walletsData = JSONUtil.unwrap(obj)
                    break
                }
            }
        }

        if contextData == nil && balanceData == nil && walletsData == nil {
            if lastStatus == 401 || lastStatus == 403 {
                throw BridgeError.unauthorized("千问Work登录已过期，请打开客户端刷新")
            }
            throw BridgeError.network("请求千问Work接口失败")
        }

        var resetDate: Date?
        if isBiz {
            for ePath in ["/biz/user/v1/settings/enterprise/quota", "/api/v1/adapter/biz/settings/enterprise/quota"] {
                if let r = try? await AsyncHTTP.getJSON(url: "\(apiOrigin)\(ePath)", headers: headers, timeout: 5),
                   r.status == 200, let obj = r.json
                {
                    let uw = JSONUtil.unwrap(obj)
                    resetDate = JSONUtil.parseDate(uw["next_used_reset_at"] ?? uw["nextUsedResetAt"])
                    if resetDate != nil { break }
                }
            }
        }

        let quotaObj = (contextData?["quota"] as? [String: Any])
            ?? (contextData?["user_quota"] as? [String: Any])
            ?? (contextData?["userQuota"] as? [String: Any])
            ?? balanceData
            ?? contextData
            ?? [:]

        if resetDate == nil {
            resetDate = JSONUtil.parseDate(
                quotaObj["next_reset_at"] ?? quotaObj["nextResetAt"] ?? quotaObj["expires_at"] ?? quotaObj["expiresAt"]
            )
        }

        func parseDict(_ d: [String: Any]?) -> DesktopQuotaSnapshot? {
            guard let d,
                  let total = JSONUtil.double(d["total"] ?? d["cap"] ?? d["limit"] ?? d["total_balance"] ?? d["totalBalance"]),
                  total > 0
            else { return nil }
            let usedOpt = JSONUtil.double(d["used"] ?? d["consumed"])
            let remOpt = JSONUtil.double(d["remaining"] ?? d["balance"] ?? d["available"] ?? d["total_balance"] ?? d["totalBalance"])
            let used = usedOpt ?? Swift.max(0, total - (remOpt ?? 0))
            let rem = remOpt ?? Swift.max(0, total - used)
            let usedPct: Double
            if let rp = JSONUtil.double(d["percentage"]) {
                usedPct = (rp >= 0 && rp <= 1.0 && total > 1) ? rp * 100.0 : rp
            } else {
                usedPct = (used / total) * 100.0
            }
            let remPct = JSONUtil.clamp(100.0 - usedPct, min: 0, max: 100)
            let itemReset = JSONUtil.parseDate(d["expires_at"] ?? d["expiresAt"] ?? d["reset_at"] ?? d["resetAt"]) ?? resetDate
            return DesktopQuotaSnapshot(
                remainingPercent: remPct,
                remainingText: JSONUtil.formatPercent(remPct),
                subText: "余 \(JSONUtil.formatInt(rem))",
                resetsAt: itemReset,
                status: JSONUtil.quotaStatus(for: remPct)
            )
        }

        let mainCandidate = (quotaObj["user_quota"] as? [String: Any])
            ?? (quotaObj["userQuota"] as? [String: Any])
            ?? quotaObj
        if let snap = parseDict(mainCandidate) {
            return snap
        }

        for keys in [
            ["daily_quota", "dailyQuota", "daily_credits", "dailyCredits"],
            ["monthly_quota", "monthlyQuota", "subscription_quota", "subscriptionQuota"],
            ["add_on_quota", "addOnQuota"],
            ["org_resource_package", "orgResourcePackage", "shared_quota", "sharedQuota"]
        ] {
            for k in keys {
                if let sub = (quotaObj[k] as? [String: Any]) ?? (balanceData?[k] as? [String: Any]),
                   let snap = parseDict(sub)
                {
                    return snap
                }
            }
        }

        var walletCredits = 0.0
        if let w = walletsData {
            for wk in ["daily_credits", "monthly_credits", "longterm_credits"] {
                if let wd = w[wk] as? [String: Any],
                   let bal = JSONUtil.double(wd["total_balance"] ?? wd["totalBalance"] ?? wd["balance"])
                {
                    walletCredits += bal
                }
            }
        }

        let standalone = JSONUtil.double(
            balanceData?["remaining"] ?? balanceData?["balance"] ?? balanceData?["total_balance"] ?? quotaObj["remaining"]
        ) ?? (walletCredits > 0 ? walletCredits : nil)

        guard let bal = standalone else {
            throw BridgeError.parse("未解析到千问Work积分字段")
        }
        let remPct = bal > 0 ? 100.0 : 0.0
        return DesktopQuotaSnapshot(
            remainingPercent: remPct,
            remainingText: JSONUtil.formatInt(bal),
            subText: "可用积分",
            resetsAt: resetDate,
            status: bal <= 0 ? "critical" : (bal < 100 ? "warning" : "ok")
        )
    }
}
