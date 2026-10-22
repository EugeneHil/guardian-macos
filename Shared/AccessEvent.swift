import Foundation

enum AccessDecision: String, Sendable, Codable, Equatable {
    case allow
    case deny
}

struct AccessEvent: Sendable, Codable, Equatable, Identifiable {
    let id: UUID
    var timestamp: Date
    var process: ProcessIdentity
    var responsible: ProcessIdentity?
    var file: String
    var decision: AccessDecision
    var ruleId: String?
}

// MARK: - Server upload format (warden-server/docs/api.md, POST /api/v1/events)

extension AccessEvent {
    /// Server limit for every string, in UTF-8 bytes.
    static let maxStringBytes = 4096

    /// Serializes a batch to the server's event format. Callers keep batches within 1...500 events.
    static func uploadPayload(_ events: [AccessEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(events.map(UploadEvent.init))
    }
}

private struct UploadProcess: Encodable {
    let path: String
    let signingId: String?
    let teamId: String?

    init(_ identity: ProcessIdentity) {
        let limit = AccessEvent.maxStringBytes
        path = identity.path.truncatedUTF8(limit)
        signingId = identity.signingId.isEmpty ? nil : identity.signingId.truncatedUTF8(limit)
        teamId = identity.teamId.isEmpty ? nil : identity.teamId.truncatedUTF8(limit)
    }
}

private struct UploadEvent: Encodable {
    let timestamp: String
    let process: UploadProcess
    let responsible: UploadProcess?
    let file: String
    let decision: AccessDecision
    let ruleId: String?

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case process, responsible, file, decision, ruleId
    }

    init(_ event: AccessEvent) {
        let limit = AccessEvent.maxStringBytes
        timestamp = event.timestamp.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
        process = UploadProcess(event.process)
        responsible = event.responsible.map(UploadProcess.init)
        file = event.file.truncatedUTF8(limit)
        decision = event.decision
        ruleId = event.ruleId.flatMap { $0.isEmpty ? nil : $0.truncatedUTF8(limit) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(process, forKey: .process)
        try container.encode(responsible, forKey: .responsible) // explicit null when absent
        try container.encode(file, forKey: .file)
        try container.encode(decision, forKey: .decision)
        try container.encodeIfPresent(ruleId, forKey: .ruleId)
    }
}

extension String {
    /// Longest prefix of at most `maxBytes` UTF-8 bytes that does not split a Unicode scalar.
    func truncatedUTF8(_ maxBytes: Int) -> String {
        guard utf8.count > maxBytes else { return self }
        var result = String.UnicodeScalarView()
        var used = 0
        for scalar in unicodeScalars {
            let size = String(scalar).utf8.count
            if used + size > maxBytes {
                break
            }
            result.append(scalar)
            used += size
        }
        return String(result)
    }
}
