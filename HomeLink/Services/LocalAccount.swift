import Darwin
import Foundation

nonisolated enum LocalAccount {
    static var home: URL {
      get throws {
        var entry = passwd(), result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let path: String? = buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(getuid(), &entry, bytes.baseAddress, bytes.count, &result) == 0,
                  result != nil, let directory = entry.pw_dir else { return nil }
            return String(cString: directory)
        }
        guard let path, path.hasPrefix("/") else { throw HomeLinkError.message("无法确认当前账户的用户位置，请稍后重试。") }
        return URL(fileURLWithPath: path, isDirectory: true)
      }
    }

}
