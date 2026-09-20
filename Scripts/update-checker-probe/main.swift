import Foundation

private var failureCount = 0

@MainActor
private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() {
        print("PASS  \(label)")
    } else {
        failureCount += 1
        print("FAIL  \(label)")
    }
}

private func version(_ value: String) -> AppVersion {
    guard let parsed = AppVersion(value) else {
        print("FAIL  could not parse \(value)")
        exit(1)
    }
    return parsed
}

print("=== YUANNotch · update checker probe ===")
print("")

check(version("0.1.0") < version("v0.2.0"), "a newer minor release is detected")
check(version("1.9.9") < version("1.10.0"), "numeric components do not sort as text")
check(version("1.0") == version("1.0.0"), "missing trailing components equal zero")
check(version("1.0.0-beta.2") < version("1.0.0-beta.10"), "numeric prerelease identifiers compare numerically")
check(version("1.0.0-beta") < version("1.0.0"), "a stable release follows its prerelease")
check(version("V2.0.0+build.4") == version("2.0.0"), "v prefixes and build metadata are ignored")
check(AppVersion("") == nil, "an empty tag is rejected")
check(AppVersion("release-1.0") == nil, "a non-semantic tag is rejected")
check(AppVersion("1..0") == nil, "an empty numeric component is rejected")

print("")
if failureCount == 0 {
    print("every check passed")
} else {
    print("\(failureCount) check(s) failed")
    exit(1)
}
