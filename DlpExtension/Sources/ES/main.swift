import EndpointSecurity
import Foundation
import os

// Entry point of the system extension. Construction order matters: the ES client must exist before the policy
// controller (it clears the ES cache), and everything below is held by top-level constants for the whole process
// lifetime (NSXPCListener.delegate is weak).

let logger = Logger(subsystem: BundleIDs.app, category: "ext")
/// Coordinator lines are fixed texts with numbers and verdicts only (no paths), so they are public.
let coordinatorLog: @Sendable (String) -> Void = { logger.notice("\($0, privacy: .public)") }
/// Controller lines are a fixed text, optionally followed by ": " and an error description that may name file
/// paths: the fixed part is public, anything after the first ": " stays private.
let controllerLog: @Sendable (String) -> Void = { line in
    if let separator = line.range(of: ": ") {
        let head = String(line[..<separator.lowerBound])
        let detail = String(line[separator.upperBound...])
        logger.notice("\(head, privacy: .public): \(detail, privacy: .private)")
    } else {
        logger.notice("\(line, privacy: .public)")
    }
}

let holder = PolicyHolder()
let store = PolicyStore(fileURL: URL(fileURLWithPath: "/Library/Application Support/Warden/policy.json"))
let queue = EventQueue()
let resolver = SecurityProcessResolver()
let coordinator = OpenCoordinator(holder: holder, resolver: resolver, events: queue, log: coordinatorLog)

let esClient: EndpointSecurityClient
do {
    esClient = try EndpointSecurityClient(coordinator: coordinator, log: logger)
} catch let EndpointSecurityClientError.newClient(result) {
    let reason = EndpointSecurityClient.describe(result)
    logger.fault("could not create the Endpoint Security client: \(reason, privacy: .public)")
    exit(EXIT_FAILURE)
} catch {
    logger.fault("could not start the Endpoint Security client: \(String(describing: error), privacy: .public)")
    exit(EXIT_FAILURE)
}

let controller = PolicyController(holder: holder, store: store, cache: esClient, log: controllerLog)
/// Loads the cached policy in the background; until it is active every event is allowed.
let startup = Task {
    do {
        try await store.prepareDirectory()
    } catch {
        controllerLog("could not prepare the policy directory: \(error.localizedDescription)")
    }
    await controller.start()
}

let service = ExtensionService(policy: controller, events: queue)
let listener = NSXPCListener(machServiceName: BundleIDs.machService)
listener.delegate = service
listener.resume()
logger.notice("extension running, pid \(getpid(), privacy: .public)")

// Park forever; the listener, the ES client and the service stay referenced by the constants above.
while true {
    try? await Task.sleep(for: .seconds(3600))
}
