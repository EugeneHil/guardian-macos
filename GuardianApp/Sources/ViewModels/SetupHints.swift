/// Setup hints shared by the popover and the settings window.
enum SetupHints {
    static let fullDiskAccess = "Open System Settings → Privacy & Security → Full Disk Access"

    /// The extension is activated but does not answer over XPC: most often Full Disk Access is missing.
    static func fullDiskAccess(sync: SyncState, extensionState: ExtensionState) -> String? {
        guard extensionState == .active, case .extensionUnavailable = sync else { return nil }
        return fullDiskAccess
    }
}
