/// Identifiers shared by the app and the extension. The Mach service must be prefixed by the app group (ADR-0001).
enum BundleIDs {
    static let app = "io.github.eugenehil.guardian"
    static let ext = app + ".ext"
    static let appGroup = "io.github.eugenehil.guardian"
    static let machService = "io.github.eugenehil.guardian.ext"
}

/// Locations on disk that the extension owns.
enum DataPaths {
    static let policyFile = "/Library/Application Support/Guardian/policy.json"
}
