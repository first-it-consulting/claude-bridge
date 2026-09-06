import AppKit
import Foundation

/// Identity of the running build, for the About panel and bug reports.
///
/// Values come from the bundle's Info.plist, which `scripts/build-app.sh`
/// writes. Running the executable directly from SwiftPM has no bundle, so each
/// lookup falls back to something honest rather than crashing or claiming a
/// version it cannot know.
enum AppInfo {
    static var name: String {
        string(for: "CFBundleName") ?? "Claude Bridge"
    }

    /// Marketing version, e.g. "0.1.0".
    static var version: String {
        string(for: "CFBundleShortVersionString") ?? "dev"
    }

    /// Build number — the commit count at build time, so two builds of the same
    /// version are still distinguishable in a bug report.
    static var build: String {
        string(for: "CFBundleVersion") ?? "0"
    }

    static var copyright: String {
        string(for: "NSHumanReadableCopyright")
            ?? "Copyright © 2026 Claude Bridge contributors"
    }

    /// "0.1.0 (42)" — the form the About panel and issue templates use.
    static var versionSummary: String { "\(version) (\(build))" }

    static let repositoryURL = URL(string: "https://github.com/first-it-consulting/claude-bridge")!

    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }

    /// Shows the standard macOS About panel.
    ///
    /// The app is an accessory with no Dock icon, so it has to be activated
    /// first or the panel opens behind whatever the user was looking at.
    @MainActor
    static func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: name,
            .applicationVersion: version,
            .version: build,
            .credits: credits,
        ])
    }

    private static var credits: NSAttributedString {
        let body = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        body.append(NSAttributedString(
            string: "Connects Claude Desktop to local and remote LLMs.\n\n",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        ))

        let link = NSAttributedString(
            string: "github.com/first-it-consulting/claude-bridge",
            attributes: [.font: font, .link: repositoryURL]
        )
        body.append(link)

        body.append(NSAttributedString(
            // Worth stating plainly on a tool with "Claude" in its name that
            // talks to Anthropic's app.
            string: "\n\nMIT licensed. An independent project, not affiliated "
                + "with or endorsed by Anthropic.",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        ))

        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        body.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: body.length))
        return body
    }
}
