import Darwin
import Foundation

/// All calls run on BackgroundExecutor.files while the caller holds the directory's security scope.
nonisolated enum AuthorizedKeysFile {
    static func read(directory: URL) throws -> [SSHPublicKey] {
        let text = try contents(directory: directory)
        var seen = Set<String>()
        return text.components(separatedBy: "\n").compactMap(SSHPublicKey.fromAuthorizedLine).filter { seen.insert($0.identity).inserted }
    }

    @discardableResult
    static func add(_ key: SSHPublicKey, directory: URL) throws -> Bool {
        try modify(directory: directory) { original in
            if original.components(separatedBy: "\n").compactMap(SSHPublicKey.fromAuthorizedLine).contains(where: { $0.identity == key.identity }) { return original }
            return original + (original.isEmpty || original.hasSuffix("\n") ? "" : "\n") + key.text + "\n"
        }
    }

    static func remove(identity: String, directory: URL) throws {
        _ = try modify(directory: directory) { original in
            original.components(separatedBy: "\n").filter { SSHPublicKey.fromAuthorizedLine($0)?.identity != identity }.joined(separator: "\n")
        }
    }

    private static func check(_ url: URL, directory: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw HomeLinkError.message("无法读取本机授权文件，请重新授权访问。")
        }
        let kind = info.st_mode & S_IFMT
        guard info.st_uid == getuid(), kind == (directory ? S_IFDIR : S_IFREG) else {
            throw HomeLinkError.message("授权位置包含链接、特殊文件或不属于当前账户。为保护已有配置，未进行修改。")
        }
    }

    private static func contents(directory: URL) throws -> String {
        try check(directory, directory: true)
        let url = directory.appendingPathComponent("authorized_keys")
        try check(url, directory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 2_097_152 else {
            throw HomeLinkError.message("授权文件过大，无法安全处理。请保留原文件并手动检查。")
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw HomeLinkError.message("授权文件不是 UTF-8 文本，未进行修改。") }
        return text
    }

    private static func modify(directory: URL, transform: (String) throws -> String) throws -> Bool {
        try check(directory, directory: true)
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw HomeLinkError.message("无法创建本机授权位置，请重新确认系统授权。")
        }
        try check(directory, directory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lockURL = directory.appendingPathComponent(".homelink-authorized.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HomeLinkError.message("无法锁定本机授权文件。") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw HomeLinkError.message("授权文件正在修改，请稍后重试。") }
        let original = try contents(directory: directory), updated = try transform(original)
        let url = directory.appendingPathComponent("authorized_keys")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard updated != original else { return false }
        // Preserve a recoverable copy without following any existing backup link.
        let backup = directory.appendingPathComponent("authorized_keys.homelink.backup")
        try check(backup, directory: false)
        try atomicWrite(Data(original.utf8), to: backup)
        guard try contents(directory: directory) == original else { throw HomeLinkError.message("授权文件被其他程序修改，请重新读取后再试。") }
        try atomicWrite(Data(updated.utf8), to: url)
        return true
    }

    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".homelink-\(UUID().uuidString)")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HomeLinkError.message("无法准备授权文件，请检查访问权限。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temp) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard Darwin.rename(temp.path, url.path) == 0 else { throw HomeLinkError.message("无法保存授权文件，原配置已保留。") }
    }
}
