//
//  AppInfo.swift
//  TypeCam
//

import Foundation

/// Build metadata and project links shown in Settings › About.
enum AppInfo {
    static let repositoryURL = URL(string: "https://github.com/mxvsh/TypeCam")!
    static let websiteURL = URL(string: "https://monawwar.com/apps/typecam")!
    static let authorName = "Monawwar Abdullah"
    static let authorHandle = "monawwarx"

    static var authorProfileURL: URL { URL(string: "https://x.com/\(authorHandle)")! }
    static var newIssueURL: URL { repositoryURL.appending(path: "issues/new") }

    static var version: String { infoString("CFBundleShortVersionString") ?? "–" }
    static var build: String { infoString("CFBundleVersion") ?? "–" }

    /// Short git commit the app was built from, e.g. `a1b2c3d` (`-dirty` if the tree had local
    /// changes). Set by scripts/release.sh; nil for local Xcode builds.
    static var commit: String? {
        guard let value = infoString("GitCommit"), !value.isEmpty, value != "dev", !value.hasPrefix("$(") else {
            return nil
        }
        return value
    }

    /// The commit on GitHub, without any `-dirty` suffix.
    static var commitURL: URL? {
        guard let hash = commit?.split(separator: "-").first else { return nil }
        return repositoryURL.appending(path: "commit/\(hash)")
    }

    /// "1.2.0 (14) · a1b2c3d", used where one line is needed.
    static var fullVersion: String {
        "\(version) (\(build))" + (commit.map { " · \($0)" } ?? "")
    }

    /// Hardware identifier such as `iPhone17,1`.
    static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Opens a post on X addressed to the author, with the app and device details filled in.
    static var feedbackURL: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let text = "@\(authorHandle) TypeCam feedback (\(fullVersion), \(deviceModel), iOS \(os.majorVersion).\(os.minorVersion)): "
        var components = URLComponents(string: "https://x.com/intent/post")!
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        return components.url!
    }

    private static func infoString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
