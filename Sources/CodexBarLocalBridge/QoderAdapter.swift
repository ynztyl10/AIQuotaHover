import Foundation

public enum QoderAdapter {
    public static let bundleIdentifiers = [
        "com.qoder.app.stable",
        "com.qoder.app"
    ]

    static var authCandidateFiles: [URL] {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return [
            appSupport.appendingPathComponent("com.qoder.app.stable/auth.v1.dat"),
            appSupport.appendingPathComponent("com.qoder.app/auth.v1.dat"),
            appSupport.appendingPathComponent("Qoder/auth.v1.dat")
        ]
    }

    static let keychainServices = [
        "Qoder App Safe Storage",
        "Qoder Safe Storage"
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
              JSONUtil.string(root["token"] ?? root["accessToken"] ?? root["access_token"]) != nil
        else {
            return ("invalid", nil)
        }
        let user = root["user"] as? [String: Any]
        let label = JSONUtil.string(user?["email"]) ?? JSONUtil.string(user?["name"]) ?? JSONUtil.string(user?["id"])
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
            throw BridgeError.notConfigured("未检测到 Qoder 登录态")
        default:
            break
        }

        guard let plain = res.plaintext,
              let root = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
              let token = JSONUtil.string(root["token"] ?? root["accessToken"] ?? root["access_token"])
        else {
            throw BridgeError.parse("无法解析 Qoder 登录凭证")
        }

        var openApiOrigins = ["https://openapi.qoder.sh"]
        if let ctxStr = JSONUtil.string(root["authenticationContext"]), ctxStr.contains(".cn") {
            openApiOrigins.insert("https://openapi.qoder.com.cn", at: 0)
        }

        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": AdapterConstants.qoderUserAgent
        ]

        var usageRoot: [String: Any]?
        var lastStatus = 0
        for origin in openApiOrigins {
            if let r = try? await AsyncHTTP.getJSON(url: "\(origin)/sash/api/v2/me/usage", headers: headers, timeout: 16) {
                lastStatus = r.status
                if r.status == 200, let obj = r.json {
                    usageRoot = JSONUtil.unwrap(obj)
                    break
                }
            }
        }

        if lastStatus == 401 || lastStatus == 403 {
            throw BridgeError.unauthorized("Qoder 登录已过期，请打开客户端刷新")
        }
        guard let body = usageRoot else {
            throw BridgeError.network("请求 Qoder 接口超时")
        }

        let q = (body["qoderUsage"] as? [String: Any])
            ?? (body["enterpriseUsage"] as? [String: Any])
            ?? body
        let resetDate = JSONUtil.parseDate(q["expiresAt"] ?? q["nextResetAt"])

        func parseBucket(_ any: Any?, fallbackReset: Date?) -> DesktopQuotaSnapshot? {
            guard let d = any as? [String: Any],
                  let total = JSONUtil.double(d["total"] ?? d["quota"] ?? d["limit"] ?? d["cap"]),
                  total > 0
            else { return nil }
            let usedOpt = JSONUtil.double(d["used"] ?? d["consumed"])
            let remOpt = JSONUtil.double(d["remaining"] ?? d["available"] ?? d["left"])
            let used = usedOpt ?? Swift.max(0, total - (remOpt ?? 0))
            let rem = remOpt ?? Swift.max(0, total - used)
            let remPct = JSONUtil.clamp((rem / total) * 100.0, min: 0, max: 100)
            return DesktopQuotaSnapshot(
                remainingPercent: remPct,
                remainingText: JSONUtil.formatPercent(remPct),
                subText: "余 \(JSONUtil.formatInt(rem))",
                resetsAt: JSONUtil.parseDate(d["expiresAt"]) ?? fallbackReset,
                status: JSONUtil.quotaStatus(for: remPct)
            )
        }

        if let planSnap = parseBucket(q["userQuota"], fallbackReset: resetDate)
            ?? parseBucket(q["addOnQuota"], fallbackReset: nil)
            ?? parseBucket(q["orgResourcePackage"], fallbackReset: resetDate)
        {
            return planSnap
        }

        if let pkgs = q["dedicatedResourcePackages"] as? [[String: Any]] {
            for pkg in pkgs where (pkg["available"] as? Bool) != false {
                if let snap = parseBucket(pkg, fallbackReset: resetDate) {
                    return snap
                }
            }
        }

        guard let exceeded = q["isQuotaExceeded"] as? Bool else {
            throw BridgeError.parse("未解析到 Qoder 积分字段")
        }
        let remPct = exceeded ? 0.0 : 100.0
        return DesktopQuotaSnapshot(
            remainingPercent: remPct,
            remainingText: exceeded ? "已耗尽" : "正常",
            subText: JSONUtil.string(body["planName"] ?? body["tier"]),
            resetsAt: resetDate,
            status: JSONUtil.quotaStatus(for: remPct)
        )
    }
}
