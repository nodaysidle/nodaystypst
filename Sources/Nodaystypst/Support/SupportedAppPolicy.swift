import Foundation

enum SupportedAppPolicy {
    static let orionBundleID = "com.kagi.kagimacOS"
    static let antinoteBundleID = "com.chabomakers.Antinote"

    static let bundleIDs: Set<String> = [
        orionBundleID,
        antinoteBundleID,
    ]

    static func allowsPredictions(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }
}
