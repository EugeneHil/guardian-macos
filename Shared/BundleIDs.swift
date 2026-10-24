/// Identifiers shared by the app and the extension. The Mach service must be prefixed by the app group (ADR-0001).
enum BundleIDs {
    static let app = "io.github.eugenehil.warden"
    static let ext = app + ".ext"
    static let appGroup = "io.github.eugenehil.warden"
    static let machService = "io.github.eugenehil.warden.ext"
}
