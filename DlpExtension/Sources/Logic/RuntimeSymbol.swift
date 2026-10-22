import Darwin

/// Looks up C symbols in the already loaded images at runtime, for APIs that exist only in newer SDKs and so
/// cannot be referenced at compile time (`#available` is a runtime check and does not help older SDKs).
enum RuntimeSymbol {
    /// The address of `name`, or nil when no loaded image exports it.
    static func address(of name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT; the macro is not imported into Swift
    }
}
