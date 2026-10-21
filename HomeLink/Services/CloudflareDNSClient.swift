import Foundation

nonisolated struct CloudflareDNSClient: Sendable {
    let session: URLSession
    init(session: URLSession = DDNSHTTP.makeSession()) { self.session = session }

    func validate(domain: String, token: String) async throws -> DNSRecordContext {
        let parts = domain.split(separator: ".")
        for offset in 0..<(parts.count - 1) {
            try Task.checkCancellation()
            let name = parts.dropFirst(offset).joined(separator: ".")
            let zones: [Zone] = try await request(path: "zones", token: token, query: ["name": name, "status": "active", "per_page": "50"])
            if let zone = zones.first(where: { $0.name.lowercased() == name }) {
                let records: [Record] = try await request(path: "zones/\(try identifier(zone.id))/dns_records", token: token, query: ["name": domain, "type": "A", "per_page": "100"])
                let matches = records.filter { $0.name.lowercased() == domain && $0.type == "A" }
                guard matches.count == 1, let record = matches.first else {
                    throw HomeLinkError.message("请先在 Cloudflare 为此域名保留一条 IPv4 A 记录；没有记录或有多条记录时，HomeLink 不会自动创建或选择。")
                }
                guard !record.proxied else { throw HomeLinkError.message("这条记录开启了代理，请先在 Cloudflare 将它设为「仅 DNS」。HomeLink 不会自动切换代理状态。") }
                _ = try identifier(record.id)
                return DNSRecordContext(zoneID: zone.id, recordID: record.id, domain: domain, address: record.content)
            }
        }
        throw HomeLinkError.message("没有找到该域名所在区域，请检查域名及令牌的区域读取权限。")
    }

    func current(_ configuration: DDNSConfiguration, token: String) async throws -> DNSRecordContext {
        let record: Record = try await request(path: recordPath(configuration), token: token)
        guard record.id == configuration.recordID, record.name.lowercased() == configuration.domain,
              record.type == "A", !record.proxied else {
            throw HomeLinkError.message("DNS 记录的名称、类型或代理状态已改变，请重新验证。原记录未修改。")
        }
        return DNSRecordContext(zoneID: configuration.zoneID, recordID: record.id, domain: record.name, address: record.content)
    }

    func update(_ configuration: DDNSConfiguration, address: String, token: String) async throws {
        let address = try PublicIPv4.normalize(address)
        let body = try JSONEncoder().encode(Content(content: address))
        let record: Record = try await request(path: recordPath(configuration), token: token, method: "PATCH", body: body)
        guard record.id == configuration.recordID, record.name.lowercased() == configuration.domain,
              record.type == "A", !record.proxied, record.content == address else {
            throw HomeLinkError.message("Cloudflare 返回的记录与预期不符，请检查控制台。")
        }
    }

    private func recordPath(_ c: DDNSConfiguration) throws -> String {
        "zones/\(try identifier(c.zoneID))/dns_records/\(try identifier(c.recordID))"
    }
    private func identifier(_ value: String) throws -> String {
        guard value.count == 32, value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw HomeLinkError.message("DNS 记录标识无效，请重新验证。") }
        return value
    }

    private func request<T: Decodable & Sendable>(path: String, token: String, query: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> T {
        var components = URLComponents(string: "https://api.cloudflare.com/client/v4/" + path)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await DDNSHTTP.data(request, session: session)
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard envelope.success, let value = envelope.result else {
            throw HomeLinkError.message("Cloudflare 未完成请求，请检查域名与令牌权限。")
        }
        return value
    }

    private struct Envelope<T: Decodable & Sendable>: Decodable, Sendable { let success: Bool; let result: T? }
    private struct Zone: Decodable, Sendable { let id: String; let name: String }
    private struct Record: Decodable, Sendable { let id: String; let name: String; let type: String; let content: String; let proxied: Bool }
    private struct Content: Encodable { let content: String }
}
