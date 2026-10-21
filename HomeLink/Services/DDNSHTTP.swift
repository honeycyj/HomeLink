import Foundation

nonisolated final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward an API token to a redirected endpoint.
        completionHandler(nil)
    }
}

nonisolated enum DDNSHTTP {
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    static func data(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, data.count <= 1_048_576 else {
            throw HomeLinkError.message("网络响应异常，请稍后重新核验记录状态。")
        }
        guard (200...299).contains(response.statusCode) else {
            throw Failure(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        return (data, response)
    }

    struct Failure: LocalizedError, Sendable {
        let status: Int
        let retryAfter: TimeInterval?
        var errorDescription: String? {
            switch status {
            case 401, 403: "令牌无效或权限不足，请授予目标区域的 DNS 编辑和区域读取权限。"
            case 429: "请求过于频繁，稍后自动重试。"
            default: "服务暂时不可用（HTTP \(status)），请稍后核验记录状态。"
            }
        }
    }
}
