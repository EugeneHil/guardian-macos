import Foundation

/// Served by the system extension; the app connects over the Mach service in `BundleIDs.machService`.
@objc protocol WardenExtensionXPC: Sendable {
    /// Validates and activates a policy (JSON); returns the applied version.
    func apply(policyData: Data) async throws -> Int64
    /// Version of the active policy; 0 means none.
    func currentPolicyVersion() async -> Int64
    /// Removes and returns up to `max` buffered events as a JSON array of `AccessEvent`.
    func drainEvents(max: Int) async -> Data
    /// Registers the app to receive `eventRecorded` callbacks.
    func subscribe(client: WardenClientXPC) async
}

/// Served by the app for live event delivery from the extension.
@objc protocol WardenClientXPC: Sendable {
    /// One JSON `AccessEvent`. Fire-and-forget (no reply): live delivery is best-effort, `drainEvents` is the
    /// reliable path, and a reply from a dead peer might never arrive.
    func eventRecorded(_ eventData: Data)
}

/// Errors that cross the XPC boundary from the extension to the app.
enum WardenXPCError {
    static let domain = "io.github.eugenehil.warden"
    /// `NSError.code` of a policy rejected by validation; `validationErrorsKey` carries the details.
    static let invalidPolicyCode = 1
    /// `userInfo` key holding the `[String]` validation lines of a rejected policy.
    static let validationErrorsKey = "WardenValidationErrors"
}

extension JSONEncoder {
    static var xpc: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var xpc: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum XPCCoding {
    static func encode(_ event: AccessEvent) throws -> Data {
        try JSONEncoder.xpc.encode(event)
    }

    static func decode(_ data: Data) throws -> AccessEvent {
        try JSONDecoder.xpc.decode(AccessEvent.self, from: data)
    }

    static func decodeList(_ data: Data) throws -> [AccessEvent] {
        try JSONDecoder.xpc.decode([AccessEvent].self, from: data)
    }
}
