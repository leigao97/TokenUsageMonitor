import Foundation

/// One rate-limit window, e.g. "Current session", "This week", "Weekly limit".
struct LimitWindow: Identifiable {
    let id: String
    let title: String
    let usedPercent: Double          // 0...100
    let resetsAt: Date?
    let windowSeconds: TimeInterval? // window length, used to estimate pace

    /// > 1 means usage is outpacing elapsed time in the window.
    var paceRatio: Double? {
        guard let r = resetsAt, let w = windowSeconds, w > 0 else { return nil }
        let elapsed = w - r.timeIntervalSinceNow
        guard elapsed > w * 0.05, elapsed <= w else { return nil }
        return (usedPercent / 100) / (elapsed / w)
    }
}

struct ProviderStatus {
    var plan: String?
    var windows: [LimitWindow] = []
    var extra: String?
    var error: String?
    var updatedAt: Date?

    var maxUsed: Double? { windows.map(\.usedPercent).max() }
}

enum FetchError: LocalizedError {
    case notLoggedIn(String)
    case unauthorized(String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let m): return m
        case .unauthorized(let m): return m
        case .rateLimited: return "Rate limited (429)."
        case .http(let c): return "Request failed: HTTP \(c)"
        case .badResponse: return "Unexpected response (the endpoint may have changed)."
        }
    }
}

enum J {
    static func double(_ a: Any?) -> Double? {
        if let n = a as? NSNumber { return n.doubleValue }
        if let s = a as? String { return Double(s) }
        return nil
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    /// Accepts ISO 8601 strings and second/millisecond epoch numbers.
    static func date(_ a: Any?) -> Date? {
        if let n = a as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        if let s = a as? String {
            return isoFrac.date(from: s) ?? iso.date(from: s)
        }
        return nil
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum HTTP {
    static func getJSON(_ req: URLRequest, reloginHint: String) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: break
        case 401, 403: throw FetchError.unauthorized(reloginHint)
        case 429:
            let header = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            throw FetchError.rateLimited(retryAfter: header.flatMap { TimeInterval($0) })
        default: throw FetchError.http(code)
        }
        guard let obj = J.object(data) else { throw FetchError.badResponse }
        return obj
    }
}
