import Testing
import Foundation
@testable import BridgeCore

@Suite("Update checker")
struct AppUpdateCheckerTests {

    @Test("equal versions report no update available")
    func equalVersions() {
        #expect(!VersionComparator.isNewer("0.3.2", "0.3.2"))
    }

    @Test("a higher patch version is newer")
    func higherPatch() {
        #expect(VersionComparator.isNewer("0.3.3", "0.3.2"))
    }

    @Test("a higher minor version is newer")
    func higherMinor() {
        #expect(VersionComparator.isNewer("0.4.0", "0.3.99"))
    }

    @Test("a higher major version is newer")
    func higherMajor() {
        #expect(VersionComparator.isNewer("1.0.0", "0.99.99"))
    }

    @Test("a pre-release is older than the release")
    func preReleaseIsOlder() {
        #expect(!VersionComparator.isNewer("0.4.0-beta.1", "0.4.0"))
        #expect(VersionComparator.isNewer("0.4.0", "0.4.0-beta.1"))
    }

    @Test("a pre-release is older than the same release number")
    func preReleaseOlderThanSameNumber() {
        #expect(!VersionComparator.isNewer("1.0.0-rc1", "1.0.0"))
    }

    @Test("a missing patch defaults to zero")
    func missingPatchDefaultsToZero() {
        #expect(VersionComparator.isNewer("1.1", "1.0.99"))
        #expect(!VersionComparator.isNewer("1.0", "1.0.1"))
    }

    @Test("a two-part newer minor is newer than three-part older")
    func twoPartVsThreePart() {
        #expect(VersionComparator.isNewer("2.0", "1.99.99"))
    }

    @Test("same version with different pre-release tags compares lexicographically")
    func preReleaseComparison() {
        #expect(VersionComparator.isNewer("0.4.0-alpha.2", "0.4.0-alpha.1"))
    }

    @Test("the notice is nil when no update is available")
    func noNoticeWhenUpToDate() {
        let result = AppUpdateChecker.Result(available: false, version: nil, downloadURL: nil)
        #expect(result.notice == nil)
    }

    @Test("the notice contains the version when an update is available")
    func noticeWhenUpdateAvailable() {
        let result = AppUpdateChecker.Result(
            available: true, version: "0.4.0", downloadURL: URL(string: "https://example.com/dmg")
        )
        #expect(result.notice == "Update available · 0.4.0")
    }

    @Test("the download URL is nil when unavailable")
    func noDownloadURLWhenUnavailable() {
        let result = AppUpdateChecker.Result(available: false, version: nil, downloadURL: nil)
        #expect(result.downloadURL == nil)
    }

    @Test("the download URL is set when available")
    func downloadURLWhenAvailable() {
        let url = URL(string: "https://github.com/example/ClaudeBridge-0.4.0.dmg")!
        let result = AppUpdateChecker.Result(available: true, version: "0.4.0", downloadURL: url)
        #expect(result.downloadURL == url)
    }
}

@Suite("Version parsing edge cases")
struct VersionParseTests {

    @Test("leading zeros are parsed as numbers")
    func leadingZeros() {
        #expect(VersionComparator.isNewer("0.1.1", "0.01.0"))
    }

    @Test("non-numeric segments are skipped")
    func nonNumericSegments() {
        // "abc" is not a valid Int so it becomes 0 after compactMap.
        #expect(!VersionComparator.isNewer("1.abc", "1.0.1"))
    }

    @Test("empty string is the oldest possible version")
    func emptyString() {
        #expect(VersionComparator.isNewer("0.1.0", ""))
    }

    @Test("version with build metadata is compared on the pre-release part")
    func buildMetadataIgnored() {
        // "0.4.0+build123" has no dash pre-release, so it is treated as a release.
        #expect(!VersionComparator.isNewer("0.4.0+build123", "0.4.0"))
        #expect(!VersionComparator.isNewer("0.4.0", "0.4.0+build123"))
    }
}
