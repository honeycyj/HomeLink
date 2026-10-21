import Foundation

/// Keep using an existing sandbox version's data in place; never replace or merge device files on upgrade.
nonisolated enum HomeLinkStorage {
    static let directory = directory(home: FileManager.default.homeDirectoryForCurrentUser)

    static func directory(home: URL) -> URL {
        let legacy = home.appendingPathComponent("Library/Containers/local.homelink.HomeLink/Data/Library/Application Support/HomeLink", isDirectory: true)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: legacy.path)
            return legacy
        } catch {
            // Access errors should surface when loading the original location, rather than showing an empty library.
            let failure = error as NSError
            if failure.domain != NSCocoaErrorDomain || ![NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code) { return legacy }
        }
        return home.appendingPathComponent("Library/Application Support/HomeLink", isDirectory: true)
    }

    static func importLegacyPreferences(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: "migration.nonSandboxPreferences.v1") else { return }
        let file = home.appendingPathComponent("Library/Containers/local.homelink.HomeLink/Data/Library/Preferences/local.homelink.HomeLink.plist")
        guard let data = try? Data(contentsOf: file),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        for key in ["localAccess.names"] {
            if defaults.object(forKey: key) == nil, let value = values[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "migration.nonSandboxPreferences.v1")
    }
}
