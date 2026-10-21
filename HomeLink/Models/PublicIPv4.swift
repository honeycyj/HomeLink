import Foundation

nonisolated enum PublicIPv4 {
    static func normalize(_ input: String) throws -> String {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]), let d = Int(parts[3]),
              [a, b, c, d].allSatisfy({ (0...255).contains($0) }),
              (1...223).contains(a), a != 10, a != 127,
              !(a == 100 && (64...127).contains(b)), !(a == 169 && b == 254),
              !(a == 172 && (16...31).contains(b)), !(a == 192 && b == 168),
              !(a == 192 && b == 0), !(a == 192 && b == 88 && c == 99),
              !(a == 198 && (18...19).contains(b)), !(a == 198 && b == 51 && c == 100),
              !(a == 203 && b == 0 && c == 113)
        else { throw HomeLinkError.message("未检测到可用的公网 IPv4，已保留原 DNS 记录。") }
        return "\(a).\(b).\(c).\(d)"
    }
}

nonisolated struct PublicIPObservation: Equatable, Sendable {
    let address: String
    let network: String
    let sources: String
}

nonisolated struct DNSRecordContext: Codable, Equatable, Sendable {
    let zoneID: String
    let recordID: String
    let domain: String
    let address: String
}

nonisolated struct DDNSPreview: Equatable, Sendable {
    let record: DNSRecordContext
    let observation: PublicIPObservation
}
