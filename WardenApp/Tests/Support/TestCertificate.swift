import CryptoKit
import Foundation
import Security

/// Builds a self-signed ECDSA P-256 X.509 v3 certificate at run time (no key or certificate files in the repo).
enum TestCertificate {
    struct Made {
        let certificate: SecCertificate
        let trust: SecTrust
        /// base64(SHA-256(DER SubjectPublicKeyInfo)), computed independently of `SPKIPin`.
        let expectedPin: String
    }

    static func make(host: String = "warden.test") throws -> Made {
        let key = P256.Signing.PrivateKey()
        let spki = [UInt8](key.publicKey.derRepresentation)
        let ecdsaWithSHA256: [UInt8] = sequence(oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let name = sequence(set(sequence(oid([0x55, 0x04, 0x03]) + tlv(0x0C, Array(host.utf8)))))
        let validity = sequence(tlv(0x17, Array("250101000000Z".utf8)) + tlv(0x17, Array("491231235959Z".utf8)))
        let version = tlv(0xA0, tlv(0x02, [0x02]))
        let serial = tlv(0x02, [0x01])
        let tbs = sequence(version + serial + ecdsaWithSHA256 + name + validity + name + spki)
        let signature = try key.signature(for: Data(tbs)).derRepresentation
        let der = sequence(tbs + ecdsaWithSHA256 + tlv(0x03, [0x00] + [UInt8](signature)))
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            throw CocoaError(.coderInvalidValue)
        }
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust)
        guard status == errSecSuccess, let trust else {
            throw CocoaError(.coderInvalidValue)
        }
        let pin = Data(SHA256.hash(data: key.publicKey.derRepresentation)).base64EncodedString()
        return Made(certificate: certificate, trust: trust, expectedPin: pin)
    }

    private static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    private static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 {
            return [UInt8(count)]
        }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func sequence(_ content: [UInt8]) -> [UInt8] {
        tlv(0x30, content)
    }

    private static func set(_ content: [UInt8]) -> [UInt8] {
        tlv(0x31, content)
    }

    private static func oid(_ encoded: [UInt8]) -> [UInt8] {
        tlv(0x06, encoded)
    }
}
