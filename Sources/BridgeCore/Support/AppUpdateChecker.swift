import Foundation

/// Checks whether a newer Claude Bridge release exists on GitHub.
///
/// Compares the running version against the latest published release tag and
/// exposes whether an update is available plus the download URL for the DMG
/// asset. Nil means the check could not be completed — for example, no network
/// at launch or a malformed release response.
public enum AppUpdateChecker {

    /// What the check found.
    public struct Result: Equatable, Sendable {

        /// True when the latest release tag is newer than the running version.
        public let available: Bool

        /// The latest release tag with the leading `v` stripped, e.g. `"0.4.0"`.
        public let version: String?

        /// A human-readable summary for the status banner, e.g. "Update available · 0.4.0".
        /// Nil when there is nothing to say — the caller should not show a banner.
        public var notice: String? {
            guard available, let version else { return nil }
            return "Update available · \(version)"
        }

        /// The URL of the DMG asset on the latest release, ready to download.
        /// Nil when the asset could not be found or the check failed.
        public let downloadURL: URL?

        public init(
            available: Bool,
            version: String?,
            downloadURL: URL?
        ) {
            self.available = available
            self.version = version
            self.downloadURL = downloadURL
        }
    }

    private static let repoOwner = "first-it-consulting"
    private static let repoName = "claude-bridge"
    private static let baseURL = URL(string: "https://api.github.com")!

    /// Fetches the latest release and decides whether an update is available.
    ///
    /// Returns nil when the network request failed or the response could not be
    /// parsed — the caller should treat that as "no update to report" rather
    /// than "we are up to date".
    public static func check(currentVersion: String) async -> Result? {
        do {
            let data = try await data(from: baseURL.appendingPathComponent(
                "/repos/\(repoOwner)/\(repoName)/releases/latest"
            ))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let tagName = json?["tag_name"] as? String,
                  let assets = json?["assets"] as? [[String: Any]] else {
                return nil
            }

            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let dmgs = assets.compactMap { $0["name"] as? String }
                .filter { $0.hasSuffix(".dmg") }
            let downloadURL = dmgs.first.map { name in
                baseURL.appendingPathComponent(
                    "/repos/\(repoOwner)/\(repoName)/releases/assets"
                ).appendingPathComponent(name)
            }

            return Result(
                available: VersionComparator.isNewer(latestVersion, currentVersion),
                version: latestVersion,
                downloadURL: downloadURL
            )
        } catch {
            return nil
        }
    }

    private static func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("claude-bridge/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return data }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static var currentVersion: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !value.isEmpty else { return "0.0.0" }
        return value
    }
}

/// Compares two dot-separated version strings.
///
/// Handles pre-release tags (anything containing `-` after the numeric part is
/// considered older than the same release without a suffix) and falls back to
/// string comparison when numeric comparison is not possible.
enum VersionComparator {

    /// Returns true when `newer` is strictly greater than `older`.
    static func isNewer(_ newer: String, _ older: String) -> Bool {
        let (newBase, newPre) = splitVersion(newer)
        let (oldBase, oldPre) = splitVersion(older)
        let newParts = parse(newBase)
        let oldParts = parse(oldBase)
        let maxCount = max(newParts.count, oldParts.count)

        for i in 0..<maxCount {
            let newNum = i < newParts.count ? newParts[i] : 0
            let oldNum = i < oldParts.count ? oldParts[i] : 0
            if newNum > oldNum { return true }
            if newNum < oldNum { return false }
        }

        // Same numeric parts — the one without a pre-release suffix wins.
        if newPre.isEmpty, !oldPre.isEmpty { return true }
        if !newPre.isEmpty, oldPre.isEmpty { return false }
        // Lexicographic comparison works for most tags, but numeric segments
        // inside a pre-release (e.g. "alpha.2" vs "alpha.1") need numeric
        // comparison to get the right answer.
        return comparePreRelease(newPre, oldPre) == .orderedDescending

        func comparePreRelease(_ a: String, _ b: String) -> ComparisonResult {
            let aParts = a.split(separator: ".", omittingEmptySubsequences: false)
            let bParts = b.split(separator: ".", omittingEmptySubsequences: false)
            let maxCount = max(aParts.count, bParts.count)
            for i in 0..<maxCount {
                let aPart = i < aParts.count ? String(aParts[i]) : ""
                let bPart = i < bParts.count ? String(bParts[i]) : ""
                if let aNum = Int(aPart), let bNum = Int(bPart) {
                    if aNum != bNum { return aNum < bNum ? .orderedAscending : .orderedDescending }
                } else {
                    if let aNum = Int(aPart) { return .orderedDescending }
                    if let bNum = Int(bPart) { return .orderedAscending }
                    if aPart != bPart { return aPart.compare(bPart) }
                }
            }
            return .orderedSame
        }

        func splitVersion(_ version: String) -> (base: String, pre: String) {
            guard let dash = version.firstIndex(of: "-") else { return (version, "") }
            let base = String(version[..<dash])
            let pre = String(version[dash...] + "")
            return (base, pre)
        }

        func parse(_ version: String) -> [Int] {
            version.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
                .compactMap { Int($0) }
        }
    }
}
