import Foundation

nonisolated struct PublicIPDetector: Sendable {
    static let rules = "DOMAIN,checkip.amazonaws.com,DIRECT\nDOMAIN,myip.opendns.com,DIRECT\nIP-CIDR,208.67.222.222/32,DIRECT,no-resolve\nDOMAIN,api.ipify.org,DIRECT\nDOMAIN,4.ident.me,DIRECT"
    private static let primary = Source(name: "Amazon Check IP", url: "https://checkip.amazonaws.com")
    private static let backups = [Source(name: "ipify", url: "https://api.ipify.org"),
                                  Source(name: "ident.me", url: "https://4.ident.me")]
    private struct Source: Sendable { let name: String; let url: String }
    let session: URLSession
    let dnsQuery: @Sendable () async throws -> String
    let networkIdentity: @Sendable () async throws -> String

    init(session: URLSession = DDNSHTTP.makeSession(),
         dnsQuery: @escaping @Sendable () async throws -> String = { try await Self.openDNS() },
         networkIdentity: @escaping @Sendable () async throws -> String = { try await DDNSNetworkIdentity.current() }) {
        self.session = session; self.dnsQuery = dnsQuery; self.networkIdentity = networkIdentity
    }

    func observe() async throws -> PublicIPObservation {
        try Task.checkCancellation()
        let before = try await networkIdentity()
        async let primary = try? httpsAddress(Self.primary)
        async let dns = try? dnsQuery()
        let (httpsValue, dnsValue) = await (primary, dns)
        try Task.checkCancellation()
        var readings: [(name: String, address: String)] = []
        if let httpsValue { readings.append((Self.primary.name, httpsValue)) }
        if let dnsValue, let address = try? PublicIPv4.normalize(dnsValue) {
            readings.append(("OpenDNS", address))
        }
        if readings.count < 2 {
            let backups = await withTaskGroup(of: (String, String?).self) { group in
                for source in Self.backups {
                    group.addTask { (source.name, try? await httpsAddress(source)) }
                }
                var results: [(name: String, address: String)] = []
                for await (name, address) in group {
                    if let address { results.append((name, address)) }
                }
                return results.sorted { $0.name < $1.name }
            }
            readings.append(contentsOf: backups)
        }
        try Task.checkCancellation()
        guard Set(readings.map(\.address)).count <= 1 else {
            throw HomeLinkError.message("查询来源返回的公网 IP 不一致，未更新 DNS。请点击公网 IPv4 旁的说明图标，检查所有查询地址的直连规则。")
        }
        guard readings.count >= 2, let address = readings.first?.address else {
            throw HomeLinkError.message("可用的公网 IP 查询来源不足两个，未更新 DNS。请查看直连说明后重试。")
        }
        guard before == (try await networkIdentity()) else {
            throw HomeLinkError.message("检测期间本地网络发生变化，请重新验证。")
        }
        return PublicIPObservation(address: address, network: before,
                                   sources: readings.map(\.name).joined(separator: "、"))
    }

    private func httpsAddress(_ source: Source) async throws -> String {
        var request = URLRequest(url: URL(string: source.url)!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        let (data, _) = try await DDNSHTTP.data(request, session: session)
        guard data.count < 256, let text = String(data: data, encoding: .utf8) else {
            throw HomeLinkError.message("公网地址响应异常。")
        }
        return try PublicIPv4.normalize(text)
    }

    static func openDNS() async throws -> String {
        do {
            let text = try await DDNSCommandOutput.read("/usr/bin/dig", arguments: ["-4", "+short", "myip.opendns.com", "@208.67.222.222", "+time=5", "+tries=1"], timeout: 8)
            return try parseDNS(text)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw HomeLinkError.message("OpenDNS 公网 IP 查询失败。请确认 208.67.222.222 的 DNS 查询使用直连，未修改 DNS。")
        }
    }

    static func parseDNS(_ text: String) throws -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == 1, let line = lines.first else { throw HomeLinkError.message("OpenDNS 未返回唯一的公网 IPv4。") }
        return try PublicIPv4.normalize(line)
    }
}
