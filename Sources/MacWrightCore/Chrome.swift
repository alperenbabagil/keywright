// Chrome launching logic that needs no permissions: channels, profiles read from Chrome's
// `Local State`, profile lookup and the command line. The app side (Apps.swift) runs it.
import Foundation

public enum ChromeChannel: String, CaseIterable, Sendable {
    case stable, beta, dev, canary, chromium

    public var bundleId: String {
        switch self {
        case .stable: return "com.google.Chrome"
        case .beta: return "com.google.Chrome.beta"
        case .dev: return "com.google.Chrome.dev"
        case .canary: return "com.google.Chrome.canary"
        case .chromium: return "org.chromium.Chromium"
        }
    }

    /// The default user data dir, relative to ~/Library/Application Support.
    public var userDataSubpath: String {
        switch self {
        case .stable: return "Google/Chrome"
        case .beta: return "Google/Chrome Beta"
        case .dev: return "Google/Chrome Dev"
        case .canary: return "Google/Chrome Canary"
        case .chromium: return "Chromium"
        }
    }

    public static func parse(_ s: String?) throws -> ChromeChannel {
        guard let s, !s.isEmpty else { return .stable }
        let k = s.lowercased()
        if k == "chrome" || k == "release" { return .stable }
        guard let c = ChromeChannel(rawValue: k) else {
            throw ToolError("unknown channel \(s): use \(allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return c
    }
}

public struct ChromeProfile: Equatable, Sendable {
    /// Directory under the user data dir ("Default", "Profile 1"): what --profile-directory takes.
    public var directory: String
    /// The name shown in Chrome's profile menu ("Person 1", "Work").
    public var name: String
    /// Signed-in Google account, if any.
    public var email: String
    public var gaiaName: String

    public init(directory: String, name: String, email: String = "", gaiaName: String = "") {
        self.directory = directory; self.name = name; self.email = email; self.gaiaName = gaiaName
    }

    public var json: [String: Any] { ["directory": directory, "name": name, "email": email, "gaiaName": gaiaName] }
}

public enum Chrome {
    public struct LocalState {
        public var profiles: [ChromeProfile]
        public var lastUsed: String?
    }

    /// Profiles from the `Local State` JSON (profile.info_cache), sorted by directory.
    public static func parseLocalState(_ data: Data) throws -> LocalState {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any] else {
            throw ToolError("Chrome Local State has no profile section")
        }
        let cache = profile["info_cache"] as? [String: Any] ?? [:]
        let profiles = cache.compactMap { dir, v -> ChromeProfile? in
            guard let info = v as? [String: Any] else { return nil }
            return ChromeProfile(directory: dir, name: info["name"] as? String ?? dir,
                                 email: info["user_name"] as? String ?? "", gaiaName: info["gaia_name"] as? String ?? "")
        }.sorted { a, b in a.directory.localizedStandardCompare(b.directory) == .orderedAscending }
        return LocalState(profiles: profiles, lastUsed: profile["last_used"] as? String)
    }

    /// Finds a profile by directory, display name or email (exact, case-insensitive), then by a
    /// unique substring of name / email / Google name.
    public static func resolve(_ query: String, in profiles: [ChromeProfile]) throws -> ChromeProfile {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { throw ToolError("empty profile") }
        for key in [\ChromeProfile.directory, \.email, \.name, \.gaiaName] {
            let hits = profiles.filter { $0[keyPath: key].lowercased() == q }
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { throw ambiguous(query, hits) }
        }
        let hits = profiles.filter { p in [p.name, p.email, p.gaiaName].contains { $0.lowercased().contains(q) } }
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 { throw ambiguous(query, hits) }
        throw ToolError("no Chrome profile matches \(query); profiles: \(describe(profiles))")
    }

    private static func ambiguous(_ q: String, _ hits: [ChromeProfile]) -> ToolError {
        ToolError("profile \(q) matches several Chrome profiles: \(describe(hits)); pass the directory")
    }

    private static func describe(_ ps: [ChromeProfile]) -> String {
        ps.isEmpty ? "(none)" : ps.map { "\($0.directory) = \($0.name)\($0.email.isEmpty ? "" : " <\($0.email)>")" }
            .joined(separator: ", ")
    }

    public struct Options: Sendable {
        public var urls: [String] = []
        public var profileDirectory: String?
        public var userDataDir: String?
        public var newWindow = false
        public var incognito = false
        public var guest = false
        /// Opens this URL as an app window (--app=URL) instead of a tab.
        public var appURL: String?
        public var remoteDebuggingPort: Int?
        public var extraArgs: [String] = []
        public init() {}
    }

    /// The Chrome command line. Chrome hands it to an already running instance with the same user
    /// data dir, so it works whether Chrome is running or not.
    public static func arguments(_ o: Options) throws -> [String] {
        if o.incognito && o.guest { throw ToolError("incognito and guest can't both be set") }
        if o.appURL != nil && (o.incognito || o.guest) { throw ToolError("appUrl can't be combined with incognito or guest") }
        for u in o.urls + [o.appURL].compactMap({ $0 }) where u.hasPrefix("-") {
            throw ToolError("url \(u) looks like a flag; pass flags in args")
        }
        var a: [String] = []
        if let d = o.userDataDir { a.append("--user-data-dir=\(d)") }
        if let p = o.profileDirectory { a.append("--profile-directory=\(p)") }
        if let port = o.remoteDebuggingPort {
            guard (1...65535).contains(port) else { throw ToolError("remoteDebuggingPort must be 1-65535") }
            a.append("--remote-debugging-port=\(port)")
        }
        if o.incognito { a.append("--incognito") }
        if o.guest { a.append("--guest") }
        if o.newWindow { a.append("--new-window") }
        a += o.extraArgs
        if let app = o.appURL { a.append("--app=\(app)") }
        a += o.urls
        return a
    }
}
