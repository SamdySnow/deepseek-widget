import Foundation

/// DeepSeek 余额接口客户端。
/// 接口：`GET https://api.deepseek.com/user/balance`，鉴权 `Authorization: Bearer <key>`。
final class DeepSeekAPI {

    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    struct BalanceInfo {
        var currency: String
        var total: Double
        var granted: Double
        var toppedUp: Double
    }

    enum APIError: LocalizedError {
        case noKey
        case http(Int)
        case transient(String)
        case shape
        case parse

        var errorDescription: String? {
            switch self {
            case .noKey: return "未配置 DEEPSEEK_API_KEY"
            case .http(let code): return "余额接口返回 HTTP \(code)"
            case .transient(let m): return "网络请求失败：\(m)"
            case .shape: return "余额接口返回结构异常"
            case .parse: return "余额接口返回不是合法 JSON"
            }
        }

        /// 瞬时抖动（网络 / 5xx）不应当作错误展示，沿用最近一次余额即可。
        var isTransient: Bool {
            switch self {
            case .transient: return true
            case .http(let code): return code >= 500 || code == 429
            default: return false
            }
        }
    }

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    /// 拉取余额；失败时重试一次（冷启动网络/代理未就绪）。
    func fetchBalance(key: String) async throws -> BalanceInfo {
        var lastError: Error = APIError.transient("未知错误")
        for attempt in 0..<2 {
            do {
                return try await fetchOnce(key: key)
            } catch let error as APIError {
                lastError = error
                if !error.isTransient { throw error }
            } catch {
                lastError = APIError.transient(error.localizedDescription)
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        throw lastError
    }

    private func fetchOnce(key: String) async throws -> BalanceInfo {
        var request = URLRequest(url: Self.balanceURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transient(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.parse
        }
        guard let infos = root["balance_infos"] as? [[String: Any]],
              let first = infos.first else { throw APIError.shape }

        func number(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            if let s = any as? String { return Double(s) }
            return nil
        }
        guard let total = number(first["total_balance"]) else { throw APIError.shape }
        return BalanceInfo(currency: (first["currency"] as? String) ?? "CNY",
                           total: total,
                           granted: number(first["granted_balance"]) ?? 0,
                           toppedUp: number(first["topped_up_balance"]) ?? 0)
    }
}
