import CryptoKit
import Foundation
import Security

/// SPKI pin = base64(SHA-256(DER SubjectPublicKeyInfo)); the server certificate is ECDSA P-256.
enum SPKIPin {
    static let digestLength = 32

    /// ASN.1 DER SubjectPublicKeyInfo prefix for an uncompressed secp256r1 point (65 bytes follow).
    static let p256Header: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]

    private static let x963Length = 65

    static func hash(x963PublicKey: Data) -> String? {
        let bytes = [UInt8](x963PublicKey)
        guard bytes.count == x963Length, bytes.first == 0x04 else {
            return nil
        }
        let digest = SHA256.hash(data: p256Header + bytes)
        return Data(digest).base64EncodedString()
    }

    static func hash(of certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attributes[kSecAttrKeyType] as? String,
              type == (kSecAttrKeyTypeECSECPrimeRandom as String),
              let bits = attributes[kSecAttrKeySizeInBits] as? Int,
              bits == 256,
              let external = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else {
            return nil
        }
        return hash(x963PublicKey: external)
    }

    /// Constant-time comparison of two pin strings (length is not secret).
    static func matches(_ actual: String, _ expected: String) -> Bool {
        let lhs = Array(actual.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}
