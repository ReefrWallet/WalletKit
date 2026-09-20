#if os(macOS)

import Darwin
import Foundation

enum MiseTool {
    static var processEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let homeDirectory {
            environment["HOME"] = homeDirectory
        }

        return environment
    }

    static var path: String? {
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { String($0) }
            .map { "\($0)/mise" } ?? []

        let candidates = pathEntries + [
            "/opt/homebrew/bin/mise",
            "/usr/local/bin/mise",
            homeDirectory.map { "\($0)/.local/bin/mise" },
            "/Users/\(NSUserName())/.local/bin/mise"
        ].compactMap { $0 }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var homeDirectory: String? {
        guard let passwd = getpwuid(getuid()) else {
            return nil
        }

        return String(cString: passwd.pointee.pw_dir)
    }
}

#endif
