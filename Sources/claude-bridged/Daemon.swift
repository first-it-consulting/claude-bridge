import BridgeCore
import Foundation

/// Headless bridge.
///
/// Runs the same server the menu bar app does, with no UI, reading the profile
/// from the shared settings file. Useful for running the bridge on a machine
/// you only reach over SSH, and for reproducing a problem without the app in
/// the way.
///
///     claude-bridged [--profile <name>] [--port <n>] [--verbose]
///
/// Deliberately not `main.swift`: top-level code runs on the main actor, so
/// blocking it to keep the process alive would also stop the server's own tasks
/// from ever being scheduled.
@main
struct Daemon {

    struct Options {
        var profileName: String?
        var port: UInt16?
        var verbose = false
    }

    static func main() async {
        let options = parseOptions()
        let settings = ProfileStore().load()

        guard let profile = options.profileName
            .flatMap({ name in settings.profiles.first { $0.name == name } })
            ?? settings.activeProfile
        else {
            fail("No profiles configured. Open Claude Bridge and add one.")
        }

        let port = options.port ?? settings.port
        let apiKey = profile.backend.keychainAccount.flatMap { Keychain.get(account: $0) }
        let log = RequestLog(capacity: settings.logCapacity)
        let router = BridgeRouter(
            profile: profile, apiKey: apiKey, token: settings.gatewayToken, log: log
        )
        let server = BridgeServer(router: router)

        do {
            try await server.start(port: port)
        } catch {
            fail(error.localizedDescription)
        }

        print("Claude Bridge listening on http://127.0.0.1:\(port)")
        print("  profile: \(profile.name) → \(profile.backend.normalizedBase) (\(profile.backend.kind.rawValue))")
        print("  models:  \(profile.enabledModels.map(\.upstreamID).joined(separator: ", "))")
        fflush(stdout)

        if options.verbose {
            _ = await log.observe { entries in
                guard let entry = entries.first, entry.duration != nil else { return }
                let elapsed = entry.duration.map { " \(Int($0 * 1000))ms" } ?? ""
                print("[\(entry.statusText)] \(entry.method) \(entry.path) \(entry.upstreamModel ?? "")\(elapsed)")
                fflush(stdout)
            }
        }

        await waitForInterrupt()

        print("\nStopping…")
        await server.shutdown()
    }

    /// Suspends until Ctrl-C, without blocking a thread.
    static func waitForInterrupt() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            source.setEventHandler {
                source.cancel()
                continuation.resume()
            }
            source.resume()
            // The dispatch source only sees the signal if the default handler
            // is disarmed first.
            signal(SIGINT, SIG_IGN)
            // Held by the event handler until it fires.
            interruptSource = source
        }
    }

    nonisolated(unsafe) private static var interruptSource: DispatchSourceSignal?

    static func parseOptions() -> Options {
        var options = Options()
        var arguments = Array(CommandLine.arguments.dropFirst())

        while let argument = arguments.first {
            arguments.removeFirst()
            switch argument {
            case "--profile":
                options.profileName = arguments.first
                if !arguments.isEmpty { arguments.removeFirst() }
            case "--port":
                options.port = arguments.first.flatMap(UInt16.init)
                if !arguments.isEmpty { arguments.removeFirst() }
            case "--verbose", "-v":
                options.verbose = true
            case "--help", "-h":
                print("""
                    claude-bridged — run Claude Bridge without the menu bar app

                      --profile <name>   Profile to serve (default: the active one)
                      --port <n>         Port to listen on (default: from settings)
                      --verbose          Log each completed request to stdout
                    """)
                exit(0)
            default:
                fail("Unknown option: \(argument)")
            }
        }
        return options
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
