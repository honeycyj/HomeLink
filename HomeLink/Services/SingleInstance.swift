import AppKit
import Darwin

/// Hold an advisory lock for the application's lifetime, including across build locations.
@MainActor
enum SingleInstance {
    private static var descriptor: Int32 = -1

    static func acquire() {
        let directory = HomeLinkStorage.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            failToStart()
        }

        let path = directory.appending(path: "instance.lock").path
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { failToStart() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            descriptor = -1
            if lockError == EWOULDBLOCK {
                if let identifier = Bundle.main.bundleIdentifier {
                    NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                        .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
                        .activate()
                }
                exit(EXIT_SUCCESS)
            }
            failToStart()
        }
        // Keep the file and descriptor: unlinking a held lock would allow another instance in.
    }

    private static func failToStart() -> Never {
        let alert = NSAlert()
        alert.messageText = "HomeLink 无法启动"
        alert.informativeText = "无法访问本机应用数据，请退出后重试。"
        alert.runModal()
        exit(EXIT_FAILURE)
    }
}
