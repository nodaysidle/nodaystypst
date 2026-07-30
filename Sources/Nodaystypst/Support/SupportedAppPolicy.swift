import Foundation

enum SupportedAppPolicy {
    struct Target: Equatable, Sendable {
        let name: String
        let bundleID: String
        let offersTabAccept: Bool
    }

    static let orionBundleID = "com.kagi.kagimacOS"
    static let antinoteBundleID = "com.chabomakers.Antinote"
    static let bearBundleID = "net.shinyfrog.bear"
    static let chatgptBundleID = "com.openai.codex"
    static let ghosttyBundleID = "com.mitchellh.ghostty"
    static let textEditBundleID = "com.apple.TextEdit"
    static let notesBundleID = "com.apple.Notes"
    static let safariBundleID = "com.apple.Safari"
    static let chromeBundleID = "com.google.Chrome"
    static let obsidianBundleID = "md.obsidian"

    static let tabAcceptTargets: [Target] = [
        Target(name: "Orion", bundleID: orionBundleID, offersTabAccept: true),
        Target(name: "Antinote", bundleID: antinoteBundleID, offersTabAccept: true),
        Target(name: "Bear", bundleID: bearBundleID, offersTabAccept: true),
        Target(name: "ChatGPT", bundleID: chatgptBundleID, offersTabAccept: true),
        Target(name: "TextEdit", bundleID: textEditBundleID, offersTabAccept: true),
        Target(name: "Notes", bundleID: notesBundleID, offersTabAccept: true),
        Target(name: "Safari", bundleID: safariBundleID, offersTabAccept: true),
        Target(name: "Obsidian", bundleID: obsidianBundleID, offersTabAccept: true),
    ]

    static let displayOnlyTargets: [Target] = [
        Target(name: "Ghostty", bundleID: ghosttyBundleID, offersTabAccept: false),
    ]

    /// Known hosts that stay content-blind because live AX verification cannot
    /// provide trustworthy caret geometry. Keep these visible in Settings so
    /// safe rejection is explicit rather than silently advertised as support.
    static let safeRejectedTargets: [Target] = [
        Target(name: "Chrome", bundleID: chromeBundleID, offersTabAccept: false),
    ]

    static let targets = tabAcceptTargets + displayOnlyTargets
    static let bundleIDs = Set(targets.map(\.bundleID))

    private static let editableRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
    ]

    /// These eligible hosts expose their address/search chrome as ordinary AX text
    /// fields with incomplete or empty metadata. Restrict them to text areas
    /// so browser chrome and Obsidian utility fields are rejected before any
    /// value read; verified page/editor text areas remain eligible.
    private static let textAreaOnlyBundleIDs: Set<String> = [
        orionBundleID,
        safariBundleID,
        obsidianBundleID,
    ]

    private static let excludedMetadataMarkers = [
        "address and search",
        "address bar",
        "location bar",
        "omnibox",
        "smart search field",
        "search or enter address",
        "search or enter website",
        "search google or type a url",
    ]

    static func allowsPredictions(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    /// Evaluates only AX role/metadata so callers can reject browser chrome and
    /// non-editable controls before reading a field's value.
    static func allowsField(
        bundleID: String,
        role: String?,
        metadata: [String]
    ) -> Bool {
        guard allowsPredictions(bundleID: bundleID),
              let role,
              editableRoles.contains(role) else {
            return false
        }

        guard !textAreaOnlyBundleIDs.contains(bundleID)
                || role == "AXTextArea" else {
            return false
        }

        let normalizedMetadata = metadata
            .map { $0.lowercased() }
            .joined(separator: " ")
        guard !normalizedMetadata.contains("axsearchfield") else {
            return false
        }
        return !excludedMetadataMarkers.contains { marker in
            normalizedMetadata.contains(marker)
        }
    }
}
