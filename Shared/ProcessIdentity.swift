/// Identity of a process as seen by Endpoint Security. An empty string means the value is absent.
struct ProcessIdentity: Sendable, Codable, Equatable {
    var path: String
    var signingId: String
    var teamId: String

    static let unknown = ProcessIdentity(path: "", signingId: "", teamId: "")
}
