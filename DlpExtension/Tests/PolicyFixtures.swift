import Foundation

enum PolicyFixtures {
    static func policy(version: Int, target: String = "**/.secrets") -> Data {
        let json = """
        {"schemaVersion":1,"version":\(version),"rules":[{"id":"r\(version)","description":"d",\
        "targets":["\(target)"],"action":"deny","processes":[{"path":"/usr/bin/python3"}]}]}
        """
        return Data(json.utf8)
    }

    static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("guardian-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
