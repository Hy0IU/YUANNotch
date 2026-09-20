import AppKit
import Foundation

/// Checks GitHub for a newer stable release. Downloads remain an explicit user
/// action in the browser; the app never replaces its own bundle.
@MainActor
final class UpdateChecker: NSObject {
    private enum CheckKind {
        case automatic
        case manual
    }

    private struct GitHubRelease: Sendable {
        let tagName: String
        let htmlURL: URL
    }

    private enum CheckError: LocalizedError {
        case unavailableInDevelopmentBuild
        case noPublishedRelease
        case invalidResponse
        case invalidReleaseVersion(String)
        case server(Int)

        var errorDescription: String? {
            switch self {
            case .unavailableInDevelopmentBuild:
                return "Update checks are available in the packaged app."
            case .noPublishedRelease:
                return "YUANNotch does not have a published GitHub release yet."
            case .invalidResponse:
                return "GitHub returned an unreadable response."
            case .invalidReleaseVersion(let tag):
                return "The latest release has an unsupported version tag: \(tag)."
            case .server(let status):
                return "GitHub returned HTTP \(status)."
            }
        }
    }

    private static let latestReleaseURL = URL(
        string: "https://github.com/Hy0IU/YUANNotch/releases/latest"
    )!
    private static let releaseTagPathPrefix = "/Hy0IU/YUANNotch/releases/tag/"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let pollInterval: TimeInterval = 60 * 60
    private static let lastCheckKey = "yuanNotch.updates.lastAutomaticCheck"
    private static let lastPresentedVersionKey = "yuanNotch.updates.lastPresentedVersion"

    private let defaults: UserDefaults
    private var automaticTimer: Timer?
    private var checkTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    func startAutomaticChecks() {
        guard automaticTimer == nil else { return }

        checkAutomaticallyIfNeeded()
        let timer = Timer(
            timeInterval: Self.pollInterval,
            target: self,
            selector: #selector(checkAutomaticallyIfNeeded),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        automaticTimer = timer
    }

    func checkManually() {
        performCheck(.manual)
    }

    @objc private func checkAutomaticallyIfNeeded() {
        guard currentVersion != nil else { return }

        let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= Self.checkInterval else { return }

        // Record the attempt before starting it so a temporary network failure
        // does not cause an hourly retry loop in a long-running menu-bar app.
        defaults.set(Date(), forKey: Self.lastCheckKey)
        performCheck(.automatic)
    }

    private var currentVersion: (display: String, parsed: AppVersion)? {
        guard let display = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        let parsed = AppVersion(display) else {
            return nil
        }
        return (display, parsed)
    }

    private func performCheck(_ kind: CheckKind) {
        guard checkTask == nil else {
            if kind == .manual {
                showMessage(
                    title: "Checking for Updates",
                    message: "An update check is already in progress."
                )
            }
            return
        }

        guard let currentVersion else {
            finish(kind, result: .failure(CheckError.unavailableInDevelopmentBuild))
            return
        }

        var request = URLRequest(
            url: Self.latestReleaseURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "HEAD"
        request.setValue(
            "YUANNotch/\(currentVersion.display)",
            forHTTPHeaderField: "User-Agent"
        )

        checkTask = Task { [weak self] in
            guard let self else { return }

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse else {
                    throw CheckError.invalidResponse
                }
                guard (200..<400).contains(response.statusCode) else {
                    throw CheckError.server(response.statusCode)
                }
                guard let releaseURL = response.url else {
                    throw CheckError.invalidResponse
                }
                guard releaseURL.host?.lowercased() == "github.com",
                      releaseURL.path.hasPrefix(Self.releaseTagPathPrefix) else {
                    throw CheckError.noPublishedRelease
                }

                let tagName = releaseURL.lastPathComponent
                let release = GitHubRelease(tagName: tagName, htmlURL: releaseURL)
                guard let releaseVersion = AppVersion(release.tagName) else {
                    throw CheckError.invalidReleaseVersion(release.tagName)
                }

                finish(
                    kind,
                    result: .success((release, releaseVersion, currentVersion))
                )
            } catch {
                finish(kind, result: .failure(error))
            }
        }
    }

    private typealias SuccessfulCheck = (
        release: GitHubRelease,
        releaseVersion: AppVersion,
        currentVersion: (display: String, parsed: AppVersion)
    )

    private func finish(_ kind: CheckKind, result: Result<SuccessfulCheck, Error>) {
        checkTask = nil

        switch result {
        case .success(let value):
            guard value.releaseVersion > value.currentVersion.parsed else {
                if kind == .manual {
                    showMessage(
                        title: "YUANNotch Is Up to Date",
                        message: "You are using version \(value.currentVersion.display)."
                    )
                }
                return
            }

            if kind == .automatic,
               defaults.string(forKey: Self.lastPresentedVersionKey) == value.release.tagName {
                return
            }
            defaults.set(value.release.tagName, forKey: Self.lastPresentedVersionKey)
            showAvailableUpdate(
                release: value.release,
                currentVersion: value.currentVersion.display
            )

        case .failure(let error):
            guard kind == .manual else { return }
            showMessage(
                title: "Unable to Check for Updates",
                message: error.localizedDescription
            )
        }
    }

    private func showAvailableUpdate(release: GitHubRelease, currentVersion: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "YUANNotch \(release.tagName) Is Available"
        alert.informativeText = "You are using version \(currentVersion). Download the new version from GitHub when you are ready."
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Minimal SemVer comparison for GitHub tags such as `v0.2.0` and
/// `1.0.0-beta.2`. Build metadata is intentionally ignored.
struct AppVersion: Comparable {
    private enum PrereleaseIdentifier: Equatable {
        case number(Int)
        case text(String)
    }

    private let numbers: [Int]
    private let prerelease: [PrereleaseIdentifier]?

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        let buildParts = value.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let numericAndPrerelease = buildParts.first,
              !numericAndPrerelease.isEmpty,
              buildParts.count == 1 || !buildParts[1].isEmpty else {
            return nil
        }
        value = String(numericAndPrerelease)

        let versionParts = value.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard let numericVersion = versionParts.first, !numericVersion.isEmpty else {
            return nil
        }
        let numberParts = numericVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard !numberParts.isEmpty,
              numberParts.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else {
            return nil
        }

        numbers = numberParts.compactMap { Int(String($0)) }
        if versionParts.count == 2 {
            let identifiers = versionParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
            prerelease = identifiers.map { identifier in
                if let number = Int(identifier) {
                    return .number(number)
                }
                return .text(String(identifier).lowercased())
            }
        } else {
            prerelease = nil
        }
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return false }
        }
        return lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (.some(let left), .some(let right)):
            for index in 0..<min(left.count, right.count) {
                if left[index] == right[index] { continue }
                switch (left[index], right[index]) {
                case (.number(let lhs), .number(let rhs)):
                    return lhs < rhs
                case (.number, .text):
                    return true
                case (.text, .number):
                    return false
                case (.text(let lhs), .text(let rhs)):
                    return lhs < rhs
                }
            }
            return left.count < right.count
        }
    }
}
