import CryptoKit
import Foundation
import XCTest

final class SPKIPinTests: XCTestCase {
    func testMatchesCryptoKitDerHash() {
        let publicKey = P256.Signing.PrivateKey().publicKey
        let expected = Data(SHA256.hash(data: publicKey.derRepresentation)).base64EncodedString()
        XCTAssertEqual(SPKIPin.hash(x963PublicKey: publicKey.x963Representation), expected)
    }

    func testHeaderIsTwentySixBytes() {
        XCTAssertEqual(SPKIPin.p256Header.count, 26)
    }

    func testRejectsWrongLengthKey() {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        XCTAssertNil(SPKIPin.hash(x963PublicKey: key.dropLast()))
        XCTAssertNil(SPKIPin.hash(x963PublicKey: key + [0]))
        XCTAssertNil(SPKIPin.hash(x963PublicKey: Data()))
    }

    func testRejectsNonUncompressedPoint() {
        var key = P256.Signing.PrivateKey().publicKey.x963Representation
        key[key.startIndex] = 0x02
        XCTAssertNil(SPKIPin.hash(x963PublicKey: key))
    }

    func testMatchesIsTrueForEqualAndFalseForDifferentPin() {
        let one = Data(repeating: 1, count: 32).base64EncodedString()
        let two = Data(repeating: 2, count: 32).base64EncodedString()
        XCTAssertTrue(SPKIPin.matches(one, one))
        XCTAssertFalse(SPKIPin.matches(one, two))
        XCTAssertFalse(SPKIPin.matches(one, String(one.dropLast())))
        XCTAssertFalse(SPKIPin.matches("", one))
    }

    func testInMemoryStoreRoundTripsToken() async throws {
        let store = InMemorySecretStore()
        let initial = try await store.token()
        XCTAssertNil(initial)
        try await store.saveToken("wdn_x")
        let saved = try await store.token()
        XCTAssertEqual(saved, "wdn_x")
        try await store.deleteToken()
        let deleted = try await store.token()
        XCTAssertNil(deleted)
    }
}
