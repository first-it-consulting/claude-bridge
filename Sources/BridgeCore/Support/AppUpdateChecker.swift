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
    private static let webURL = URL(string: "https://github.com")!
    private static let timeout: TimeInterval = 15

    /// Why a check failed, worded for the Settings window.
    public enum CheckError: Error, LocalizedError, Equatable {
        case http(status: Int)
        case rateLimited
        case malformedResponse
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .http(let status): return "GitHub answered HTTP \(status)"
            case .rateLimited: return "GitHub rate limit reached — try again later"
            case .malformedResponse: return "GitHub sent an unexpected response"
            case .network(let reason): return reason
            }
        }
    }

    /// Fetches the latest release and decides whether an update is available.
    ///
    /// Asks github.com's `releases/latest` redirect first and the REST API only
    /// if that fails. The redirect is served by the website, not the API: it
    /// kept answering in a tenth of a second while `api.github.com` returned
    /// 504 after fifteen, and it does not count against the API's limit of 60
    /// unauthenticated requests an hour, which every Mac behind one NAT shares.
    ///
    /// Throws `CheckError` saying why when it cannot tell — the caller should
    /// treat that as "no update to report", not "we are up to date".
    public static func fetch(currentVersion: String) async throws -> Result {
        do {
            return try await fetchFromReleasePage(currentVersion: currentVersion)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await fetchFromAPI(currentVersion: currentVersion)
        }
    }

    /// The tag `releases/latest` redirects to, e.g. `…/releases/tag/v0.4.0`.
    static func fetchFromReleasePage(currentVersion: String) async throws -> Result {
        var request = URLRequest(
            url: webURL.appendingPathComponent("\(repoOwner)/\(repoName)/releases/latest"),
            timeoutInterval: timeout
        )
        // HEAD: the redirect is the whole answer, and URLSession follows it
        // without downloading the release page's HTML.
        request.httpMethod = "HEAD"
        request.setValue("claude-bridge/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CheckError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CheckError.http(status: http.statusCode)
        }
        guard let finalURL = response.url, let tag = releaseTag(from: finalURL) else {
            throw CheckError.malformedResponse
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Result(
            available: VersionComparator.isNewer(version, currentVersion),
            version: version,
            downloadURL: dmgURL(tag: tag, version: version)
        )
    }

    /// The tag in a `…/releases/tag/<tag>` URL; nil for anything else, which
    /// is what `releases/latest` serves when a repository has no release yet.
    static func releaseTag(from url: URL) -> String? {
        let parts = url.pathComponents
        guard parts.count >= 2, parts[parts.count - 2] == "tag",
              let tag = parts.last, !tag.isEmpty else { return nil }
        return tag
    }

    /// The DMG the release workflow attaches: `ClaudeBridge-<version>.dmg`.
    static func dmgURL(tag: String, version: String) -> URL {
        webURL.appendingPathComponent(
            "\(repoOwner)/\(repoName)/releases/download/\(tag)/ClaudeBridge-\(version).dmg"
        )
    }

    static func fetchFromAPI(currentVersion: String) async throws -> Result {
        let url = baseURL.appendingPathComponent(
            "repos/\(repoOwner)/\(repoName)/releases/latest"
        )
        let data: Data
        do {
            data = try await self.data(from: url, userAgentVersion: currentVersion)
        } catch let error as CheckError {
            throw error
        } catch {
            throw CheckError.network(error.localizedDescription)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw CheckError.malformedResponse
        }

        let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        // The asset's own `browser_download_url` is the only usable link:
        // the API's `releases/assets/{id}` endpoint takes a numeric id, not
        // a file name, and answers JSON rather than the file. Fall back to
        // the release page so the button always leads somewhere real.
        let dmgURL = assets
            .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
        let pageURL = (json["html_url"] as? String).flatMap(URL.init(string:))

        return Result(
            available: VersionComparator.isNewer(latestVersion, currentVersion),
            version: latestVersion,
            downloadURL: dmgURL ?? pageURL
        )
    }

    /// `fetch` with the reason discarded: nil when the check failed.
    public static func check(currentVersion: String) async -> Result? {
        try? await fetch(currentVersion: currentVersion)
    }

    private static func data(from url: URL, userAgentVersion: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("claude-bridge/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return data }
        guard (200...299).contains(httpResponse.statusCode) else {
            if [403, 429].contains(httpResponse.statusCode),
               httpResponse.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                throw CheckError.rateLimited
            }
            throw CheckError.http(status: httpResponse.statusCode)
        }
        return data
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
                    if Int(aPart) != nil { return .orderedDescending }
                    if Int(bPart) != nil { return .orderedAscending }
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
