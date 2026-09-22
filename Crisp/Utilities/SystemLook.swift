import Foundation

/// What the system draws, where macOS 27 changed it. Crisp follows the look of
/// the release it runs on, so anything fitted against macOS 26 stays there and
/// the newer fit only applies from 27 up.
enum SystemLook {
    static let isMacOS27OrLater =
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
}
