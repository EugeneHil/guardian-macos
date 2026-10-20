// THROWAWAY SPIKE: ES client that denies opens of any path ending in the target suffix.
import EndpointSecurity
import Foundation
import os

let log = Logger(subsystem: "dev.warden.spike", category: "ext")
let deniedSuffix = "warden-spike/secret.txt"  // ES reports resolved paths: /private/tmp/...

func path(of token: es_string_token_t) -> String {
    guard let data = token.data else { return "" }
    let buffer = UnsafeBufferPointer(start: UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self), count: token.length)
    return String(decoding: buffer, as: UTF8.self)
}

var client: OpaquePointer?
let created = es_new_client(&client) { client, message in
    guard message.pointee.event_type == ES_EVENT_TYPE_AUTH_OPEN else { return }
    let file = path(of: message.pointee.event.open.file.pointee.path)
    if file.hasSuffix(deniedSuffix) {
        log.notice("DENY \(file, privacy: .public)")
        es_respond_flags_result(client, message, 0, false)
    } else {
        es_respond_flags_result(client, message, UInt32.max, true)
    }
}
guard created == ES_NEW_CLIENT_RESULT_SUCCESS, let client else {
    log.error("es_new_client failed: \(created.rawValue)")
    exit(1)
}
var events = [ES_EVENT_TYPE_AUTH_OPEN]
guard es_subscribe(client, &events, UInt32(events.count)) == ES_RETURN_SUCCESS else {
    log.error("es_subscribe failed")
    exit(1)
}
log.notice("spike extension running, pid \(getpid())")
dispatchMain()
