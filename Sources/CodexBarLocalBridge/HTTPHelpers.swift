import Foundation

public enum BridgeError: Error, Sendable {
    case notConfigured(String)
    case needsAuthorization(String)
    case unauthorized(String)
    case network(String)
    case parse(String)

    public var message: String {
        switch self {
        case .notConfigured(let m),
             .needsAuthorization(let m),
             .unauthorized(let m),
             .network(let m),
             .parse(let m):
            return m
        }
    }
}

public struct DesktopQuotaSnapshot: Sendable {
    public let isBalance: Bool
    public let remainingPercent: Double
    public let remainingText: String
    public let subText: String?
    public let resetsAt: Date?
    public let status: String // "ok" | "warning" | "critical"

    public init(
        isBalance: Bool = false,
        remainingPercent: Double,
        remainingText: String,
        subText: String?,
        resetsAt: Date?,
        status: String
    ) {
        self.isBalance = isBalance
        self.remainingPercent = remainingPercent
        self.remainingText = remainingText
        self.subText = subText
        self.resetsAt = resetsAt
        self.status = status
    }
}

public enum AdapterConstants {
    public static let qoderUserAgent = "Qoder/0.5.17 (macOS)"
    public static let qwenWorkVersion = "2.1.0"
    public static let qwenWorkUserAgent = "QwenWorkCN/2.1.0 (macOS; arm64)"
    public static let dshClientVersion = "0.2.0"

    public static let cnyWarnThreshold = 50.0
    public static let cnyCriticalThreshold = 10.0
    public static let usdWarnThreshold = 10.0
    public static let usdCriticalThreshold = 2.0
}

enum JSONUtil {
    static func unwrap(_ root: [String: Any]) -> [String: Any] {
        for key in ["data", "result"] {
            if let inner = root[key] as? [String: Any] {
                return inner
            }
        }
        return root
    }

    static func double(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber:
            let v = n.doubleValue
            return v.isFinite ? v : nil
        case let s as String:
            if let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), v.isFinite {
                return v
            }
            return nil
        default:
            return nil
        }
    }

    static func string(_ any: Any?) -> String? {
        if let s = any as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let n = any as? NSNumber {
            return n.stringValue
        }
        return nil
    }

    static func clamp(_ v: Double, min lo: Double, max hi: Double) -> Double {
        Swift.min(hi, Swift.max(lo, v))
    }

    static func parseDate(_ any: Any?) -> Date? {
        if let num = double(any), num > 1_000_000_000 {
            let seconds = num > 100_000_000_000 ? num / 1000.0 : num
            return Date(timeIntervalSince1970: seconds)
        }
        guard let raw = string(any) else { return nil }

        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d }

        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: raw) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: raw) { return d }
        }
        return nil
    }

    static func formatInt(_ v: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.maximumFractionDigits = 0
        return fmt.string(from: NSNumber(value: v.rounded())) ?? String(format: "%.0f", v)
    }

    static func quotaStatus(for remainingPercent: Double) -> String {
        if remainingPercent <= 12 { return "critical" }
        if remainingPercent <= 30 { return "warning" }
        return "ok"
    }

    static func formatPercent(_ remPct: Double) -> String {
        (remPct >= 99.5 && remPct < 100.0) ? "99.9%" : "\(Int(remPct.rounded()))%"
    }
}

enum AsyncHTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 18
        cfg.timeoutIntervalForResource = 24
        cfg.httpAdditionalHeaders = ["Cache-Control": "no-cache"]
        return URLSession(configuration: cfg)
    }()

    static func getJSON(
        url: String,
        headers: [String: String],
        timeout: TimeInterval = 16
    ) async throws -> (status: Int, json: [String: Any]?) {
        guard let reqURL = URL(string: url) else {
            throw BridgeError.network("URL 无效")
        }
        var req = URLRequest(url: reqURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
        req.httpMethod = "GET"
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw BridgeError.network("响应无效")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (http.statusCode, obj)
    }
}
