import CryptoKit
import Foundation

/// Parses OpenSSH's wire format; a comment is never used as the identity of a key.
nonisolated struct SSHPublicKey: Equatable, Sendable {
    let kind: String
    let blob: String
    let comment: String
    var identity: String { "\(kind) \(blob)" }
    var text: String { identity + (comment.isEmpty ? "" : " \(comment)") }
    var fingerprint: String {
        let digest = SHA256.hash(data: Data(base64Encoded: blob) ?? Data())
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    init(pasted text: String) throws {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count == 1, let key = Self.fromAuthorizedLine(lines[0]),
              key.kind == "ssh-ed25519", Self.fields(lines[0]).first == "ssh-ed25519",
              let data = Data(base64Encoded: key.blob), data.count == 51,
              Array(data.prefix(19)) == [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]
        else { throw HomeLinkError.message("请粘贴一条完整的 Ed25519 公钥，以 ssh-ed25519 开头。不要粘贴私钥。") }
        self = key
    }

    private init(kind: String, blob: String, comment: String) {
        self.kind = kind; self.blob = blob; self.comment = comment
    }

    static func fromAuthorizedLine(_ line: String) -> Self? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#") else { return nil }
        let fields = fields(line)
        // OpenSSH permits exactly one options field before the key type.
        for index in [0, 1] where fields.indices.contains(index + 1) {
            let kind = fields[index], blob = fields[index + 1]
            guard kind.hasPrefix("ssh-") || kind.hasPrefix("ecdsa-") || kind.hasPrefix("sk-"),
                  let bytes = Data(base64Encoded: blob), bytes.count >= 4 else { continue }
            let size = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0, size < 128, bytes.count >= size + 4,
                  String(data: bytes.subdata(in: 4..<(size + 4)), encoding: .utf8) == kind else { continue }
            return Self(kind: kind, blob: bytes.base64EncodedString(), comment: fields.dropFirst(index + 2).joined(separator: " "))
        }
        return nil
    }

    private static func fields(_ line: String) -> [String] {
        var fields: [String] = [], word = "", quoted = false, escaped = false
        for c in line {
            if escaped { word.append(c); escaped = false; continue }
            if c == "\\" { word.append(c); escaped = true; continue }
            if c == "\"" { quoted.toggle(); word.append(c); continue }
            if c.isWhitespace && !quoted {
                if !word.isEmpty { fields.append(word); word = "" }
            } else { word.append(c) }
        }
        if !word.isEmpty { fields.append(word) }
        return fields
    }
}
