import Foundation

public enum DSHAdapter {
    public static let bundleIdentifiers = [
        "com.deepseek.dsh"
    ]

    static var dshHome: URL {
        if let custom = ProcessInfo.processInfo.environment["DSH_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let desktopSettingsCandidates = [
            home.appendingPathComponent("Library/Application Support/@deepseek-ai/dsh-desktop/desktop/settings.json"),
            home.appendingPathComponent("Library/Application Support/dsh-desktop/desktop/settings.json")
        ]
        for settingsURL in desktopSettingsCandidates {
            if let data = try? Data(contentsOf: settingsURL),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            {
                for key in ["dshHome", "homeDir", "harnessHome"] {
                    if let dir = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !dir.isEmpty
                    {
                        let expanded = (dir as NSString).expandingTildeInPath
                        if fm.fileExists(atPath: expanded) {
                            return URL(fileURLWithPath: expanded)
                        }
                    }
                }
            }
        }
        return home.appendingPathComponent(".dsh")
    }

    public static var hasDesktopAppInstalled: Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let paths = [
            "/Applications/DeepSeek Harness.app",
            "/Applications/DSH.app",
            home.appendingPathComponent("Applications/DeepSeek Harness.app").path,
            home.appendingPathComponent("Applications/DSH.app").path,
            home.appendingPathComponent("Library/Application Support/@deepseek-ai/dsh-desktop").path,
            home.appendingPathComponent("Library/Application Support/dsh-desktop").path
        ]
        return paths.contains { fm.fileExists(atPath: $0) }
    }

    struct AccountGrant {
        let token: String
        let issuer: String
    }

    struct CredentialsParsed {
        var refs: [String: String] = [:]
        var grants: [AccountGrant] = []
    }

    private static func unquoteYAML(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2,
           (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'"))
        {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    static func loadCredentials() -> CredentialsParsed {
        var out = CredentialsParsed()

        // 1) ~/.dsh/.env
        let envURL = dshHome.appendingPathComponent(".env")
        if let envRaw = try? String(contentsOf: envURL, encoding: .utf8) {
            for line in envRaw.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                if let eq = trimmed.firstIndex(of: "=") {
                    let k = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                    let v = unquoteYAML(String(trimmed[trimmed.index(after: eq)...]))
                    if !k.isEmpty && !v.isEmpty {
                        out.refs[k] = v
                    }
                }
            }
        }

        // 2) ~/.dsh/.credentials.yaml (`@deepseek-ai/dsh-credentials-local`)
        let credURL = dshHome.appendingPathComponent(".credentials.yaml")
        if let raw = try? String(contentsOf: credURL, encoding: .utf8) {
            enum Section { case none, refs, records }
            var section: Section = .none
            var curToken: String?
            var curIssuer: String?
            var curSecretRefName: String?

            func flushGrant() {
                if let t = curToken, !t.isEmpty {
                    let effectiveIssuer: String?
                    if let iss = curIssuer, !iss.isEmpty {
                        effectiveIssuer = iss
                    } else if curSecretRefName?.lowercased().contains("deepseek") == true {
                        effectiveIssuer = "https://platform.deepseek.com"
                    } else {
                        effectiveIssuer = nil
                    }
                    if let iss = effectiveIssuer {
                        out.grants.append(AccountGrant(token: t, issuer: iss))
                    }
                }
                curToken = nil
                curIssuer = nil
            }

            for line in raw.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let indent = line.prefix(while: { $0 == " " }).count

                if indent == 0 {
                    flushGrant()
                    switch trimmed {
                    case "refs:": section = .refs
                    case "records:": section = .records
                    default: section = .none
                    }
                    continue
                }

                if section == .refs && indent == 2, let colon = trimmed.firstIndex(of: ":") {
                    let k = unquoteYAML(String(trimmed[..<colon]))
                    let v = unquoteYAML(String(trimmed[trimmed.index(after: colon)...]))
                    if !k.isEmpty && !v.isEmpty { out.refs[k] = v }
                } else if section == .records {
                    if indent == 2 && trimmed.hasSuffix(":") {
                        flushGrant()
                        curSecretRefName = unquoteYAML(String(trimmed.dropLast()))
                    } else if indent >= 4, let colon = trimmed.firstIndex(of: ":") {
                        let k = unquoteYAML(String(trimmed[..<colon]))
                        let v = unquoteYAML(String(trimmed[trimmed.index(after: colon)...]))
                        if (k == "token" || k == "accessToken" || k == "authToken") && !v.isEmpty {
                            curToken = v
                        } else if (k == "issuer" || k == "origin") && !v.isEmpty {
                            curIssuer = v
                        } else if (k == "secret" || k == "value" || k == "apiKey") && !v.isEmpty, let refKey = curSecretRefName {
                            let upper = refKey.components(separatedBy: "/").last?.uppercased() ?? refKey
                            if out.refs[refKey] == nil { out.refs[refKey] = v }
                            if out.refs[upper] == nil { out.refs[upper] = v }
                            if refKey.lowercased().contains("deepseek") && v.hasPrefix("sk-") && out.refs["DEEPSEEK_API_KEY"] == nil {
                                out.refs["DEEPSEEK_API_KEY"] = v
                            }
                        }
                    }
                }
            }
            flushGrant()
        }

        // 3) Scoped fallback: ~/.dsh/settings.yaml ONLY under an explicit `deepseek` block
        if out.refs["DEEPSEEK_API_KEY"] == nil {
            for yamlName in ["settings.yaml", "cordis.patch.yml"] {
                let yamlURL = dshHome.appendingPathComponent(yamlName)
                guard let content = try? String(contentsOf: yamlURL, encoding: .utf8) else { continue }
                var deepseekSectionIndent: Int?
                for line in content.components(separatedBy: .newlines) {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || t.hasPrefix("#") { continue }
                    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                    if let secIndent = deepseekSectionIndent, indent <= secIndent {
                        deepseekSectionIndent = nil
                    }
                    guard let colon = t.firstIndex(of: ":") else { continue }
                    let k = unquoteYAML(String(t[..<colon]))
                    let v = unquoteYAML(String(t[t.index(after: colon)...]))
                    if v.isEmpty && k.lowercased().contains("deepseek") {
                        deepseekSectionIndent = indent
                        continue
                    }
                    if k == "DEEPSEEK_API_KEY", v.hasPrefix("sk-") {
                        out.refs["DEEPSEEK_API_KEY"] = v
                        break
                    }
                    if deepseekSectionIndent != nil,
                       (k == "apiKey" || k == "api_key"),
                       v.hasPrefix("sk-")
                    {
                        out.refs["DEEPSEEK_API_KEY"] = v
                        break
                    }
                }
                if out.refs["DEEPSEEK_API_KEY"] != nil { break }
            }
        }
        return out
    }

    public static func fetchSnapshot() async throws -> DesktopQuotaSnapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dshHome.path) || hasDesktopAppInstalled else {
            throw BridgeError.notConfigured("未检测到 DSH 桌面端或 ~/.dsh")
        }

        var safeThreshold = AdapterConstants.cnyWarnThreshold
        var warnThreshold = AdapterConstants.cnyCriticalThreshold
        let dashConfigURL = dshHome.appendingPathComponent("dsh-api-dashboard.json")
        if let d = try? Data(contentsOf: dashConfigURL),
           let cfg = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        {
            if let s = JSONUtil.double(cfg["safeThreshold"]), s > 0 { safeThreshold = s }
            if let w = JSONUtil.double(cfg["warnThreshold"]), w >= 0 { warnThreshold = w }
        }

        let creds = loadCredentials()
        var totalCNYBalance: Double?
        var totalUSDBalance: Double?

        // 1) Authoritative source: DeepSeek Account Platform (`deepseek-account` OAuth grant)
        for grant in creds.grants {
            let origin = grant.issuer.hasSuffix("/") ? String(grant.issuer.dropLast()) : grant.issuer
            let headers = [
                "x-dsh-auth-token": grant.token,
                "x-client-bundle-id": "",
                "x-client-platform": "desktop-mac",
                "x-client-version": AdapterConstants.dshClientVersion,
                "x-client-locale": "zh_CN",
                "x-client-timezone-offset": String(TimeZone.current.secondsFromGMT()),
                "Accept": "application/json"
            ]
            if let r = try? await AsyncHTTP.getJSON(url: "\(origin)/api/v0/users/get_user_summary", headers: headers, timeout: 10),
               r.status == 200,
               let root = r.json,
               let data = root["data"] as? [String: Any],
               let bizData = data["biz_data"] as? [String: Any]
            {
                let wallets = ((bizData["normal_wallets"] as? [[String: Any]]) ?? [])
                    + ((bizData["bonus_wallets"] as? [[String: Any]]) ?? [])
                for w in wallets {
                    guard let cur = JSONUtil.string(w["currency"]),
                          let bal = JSONUtil.double(w["balance"])
                    else { continue }
                    if cur == "CNY" { totalCNYBalance = (totalCNYBalance ?? 0) + bal }
                    if cur == "USD" { totalUSDBalance = (totalUSDBalance ?? 0) + bal }
                }
            }
        }

        // 2) Fallback source: `DEEPSEEK_API_KEY` (only when OAuth grant did not already return a wallet)
        if totalCNYBalance == nil && totalUSDBalance == nil,
           let dsKey = creds.refs["DEEPSEEK_API_KEY"], !dsKey.isEmpty
        {
            let headers = ["Authorization": "Bearer \(dsKey)", "Accept": "application/json"]
            if let r = try? await AsyncHTTP.getJSON(url: "https://api.deepseek.com/user/balance", headers: headers, timeout: 10),
               r.status == 200,
               let root = r.json,
               let infos = root["balance_infos"] as? [[String: Any]]
            {
                for info in infos {
                    guard let cur = JSONUtil.string(info["currency"]),
                          let total = JSONUtil.double(info["total_balance"])
                    else { continue }
                    if cur == "CNY" { totalCNYBalance = (totalCNYBalance ?? 0) + total }
                    if cur == "USD" { totalUSDBalance = (totalUSDBalance ?? 0) + total }
                }
            }
        }

        if let cny = totalCNYBalance {
            return DesktopQuotaSnapshot(
                isBalance: true,
                remainingPercent: cny > warnThreshold ? 100 : (cny > 0 ? 25 : 0),
                remainingText: String(format: "¥%.2f", max(0, cny)),
                subText: "DSH 桌面端 · 实时余额",
                resetsAt: nil,
                status: cny < warnThreshold ? "critical" : (cny < safeThreshold ? "warning" : "ok")
            )
        }
        if let usd = totalUSDBalance {
            return DesktopQuotaSnapshot(
                isBalance: true,
                remainingPercent: usd > AdapterConstants.usdCriticalThreshold ? 100 : (usd > 0 ? 25 : 0),
                remainingText: String(format: "$%.2f", max(0, usd)),
                subText: "DSH 桌面端 · 实时余额",
                resetsAt: nil,
                status: usd < AdapterConstants.usdCriticalThreshold
                    ? "critical"
                    : (usd < AdapterConstants.usdWarnThreshold ? "warning" : "ok")
            )
        }

        throw BridgeError.notConfigured(
            hasDesktopAppInstalled ? "已安装 DSH 桌面端 · 点击登录绑定" : "点击登录 DeepSeek 查看余额"
        )
    }
}
