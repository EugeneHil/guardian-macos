import Foundation

enum PolicyStoreError: Error, Equatable {
    case unreadable(String)
}

/// Persistence seam for `PolicyController`; `PolicyStore` is the production implementation.
protocol PolicyPersisting: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
}

/// On-disk policy cache: mode 0600, written atomically (temp file in the same directory + rename).
actor PolicyStore: PolicyPersisting {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The cached bytes, or `nil` when no cache file exists.
    func load() throws -> Data? {
        let descriptor = open(fileURL.path, O_RDONLY)
        if descriptor < 0 {
            if errno == ENOENT {
                return nil
            }
            throw PolicyStoreError.unreadable("open: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw PolicyStoreError.unreadable(error.localizedDescription)
        }
    }

    /// Creates the cache directory (mode 0700) or tightens an existing one to 0700, and removes temp files left
    /// behind by an interrupted save. Call once at startup.
    func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try createDirectory(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let prefix = ".\(fileURL.lastPathComponent)."
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names.filter({ $0.hasPrefix(prefix) && $0.hasSuffix(".tmp") }) {
            unlink(directory.appendingPathComponent(name).path)
        }
    }

    func save(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try createDirectory(directory)
        let tempURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw posixError("open") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            guard fsync(descriptor) == 0 else { throw posixError("fsync") }
            try handle.close()
            guard rename(tempURL.path, fileURL.path) == 0 else { throw posixError("rename") }
        } catch {
            try? handle.close()
            unlink(tempURL.path)
            throw error
        }
    }

    /// Missing directories are created with mode 0700 (FileManager would default to 0755); existing ones are kept.
    private func createDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    private func posixError(_ call: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(call): \(String(cString: strerror(errno)))"]
        )
    }
}
