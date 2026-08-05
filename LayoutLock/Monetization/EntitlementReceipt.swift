import CryptoKit
import Foundation

enum EntitlementSigningKey {
    static var trustedKeys: [SigningPublicKey] = {
        #if DEBUG
        return [
            SigningPublicKey(
                keyId: "test-deployed-1",
                rawRepresentationHex: "0473c529263180c050260f9d0fa071e8ca6a2308dadeb0f2eabcaaac8e083f12b7c01ce0cccadc4648f40d4b0c5cf941b28141e65097b0d00ca986a881199c0cf1",
                environment: "test"
            )
        ]
        #else
        return [
            SigningPublicKey(
                keyId: "live-2026-07-1",
                rawRepresentationHex: "04c9db4c112d22ddf2450ce89b2a03a6d8733f41923f3ba451b08333c0bd0af9be7c222e9ee45b07d4470dd533d8f099c8fba4e53819b64c7d9380904ee06e68cb",
                environment: "live"
            )
        ]
        #endif
    }()
}

struct SigningPublicKey: Equatable {
    let keyId: String
    let rawRepresentationHex: String
    let environment: String
}

enum EntitlementReceipt {
    static let expectedVersion = 1
    static let expectedIssuer = "layoutlock-proxy"
    static let expectedAudience = "layoutlock"
    static let expectedTyp = "layoutlock-entitlement+jws"

    struct VerifiedPayload: Equatable {
        let status: String
        let validatedAt: Date
        let productID: String
        let environment: String
        let instanceID: String?
        let deviceBinding: String
    }

    enum VerificationError: Error, Equatable {
        case malformed
        case unsupportedAlgorithm
        case unsupportedType
        case unknownKeyId
        case headerMismatch
        case payloadMismatch
        case productMismatch
        case environmentMismatch
        case invalidSignature
    }

    static func verify(
        receipt: String,
        deviceCredential: String,
        expectedProductID: String
    ) -> Result<VerifiedPayload, VerificationError> {
        let parts = receipt.split(separator: ".", maxSplits: 2)
        guard parts.count == 3 else {
            return .failure(.malformed)
        }

        let headerB64 = String(parts[0])
        let payloadB64 = String(parts[1])
        let signatureB64 = String(parts[2])

        guard let headerJSON = base64urlDecode(headerB64),
              let header = try? JSONSerialization.jsonObject(with: headerJSON) as? [String: Any],
              let payloadJSON = base64urlDecode(payloadB64),
              let payload = try? JSONSerialization.jsonObject(with: payloadJSON) as? [String: Any] else {
            return .failure(.malformed)
        }

        guard header["alg"] as? String == "ES256" else {
            return .failure(.unsupportedAlgorithm)
        }

        guard header["typ"] as? String == expectedTyp else {
            return .failure(.unsupportedType)
        }

        guard let kid = header["kid"] as? String,
              let signingKey = EntitlementSigningKey.trustedKeys.first(where: { $0.keyId == kid }) else {
            return .failure(.unknownKeyId)
        }

        guard payload["version"] as? Int == expectedVersion,
              payload["issuer"] as? String == expectedIssuer,
              payload["audience"] as? String == expectedAudience else {
            return .failure(.payloadMismatch)
        }

        guard let status = payload["status"] as? String,
              let validatedAtStr = payload["validatedAt"] as? String,
              let validatedAt = ISO8601DateFormatter.shared.date(from: validatedAtStr),
              let productID = payload["productID"] as? String,
              let environment = payload["environment"] as? String,
              let deviceBinding = payload["deviceBinding"] as? String else {
            return .failure(.payloadMismatch)
        }

        let instanceID = payload["instanceID"] as? String

        guard environment == signingKey.environment else {
            return .failure(.environmentMismatch)
        }

        guard productID == expectedProductID else {
            return .failure(.productMismatch)
        }

        guard let publicKey = try? P256.Signing.PublicKey(rawRepresentation: Data(hexString: signingKey.rawRepresentationHex)) else {
            return .failure(.unknownKeyId)
        }

        let signingInput = "\(headerB64).\(payloadB64)"
        guard let signatureData = base64urlDecode(signatureB64),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData) else {
            return .failure(.invalidSignature)
        }

        guard publicKey.isValidSignature(signature, for: Data(signingInput.utf8)) else {
            return .failure(.invalidSignature)
        }

        let computedBinding = SHA256.hash(data: Data(deviceCredential.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        guard deviceBinding == computedBinding else {
            return .failure(.invalidSignature)
        }

        return .success(VerifiedPayload(
            status: status,
            validatedAt: validatedAt,
            productID: productID,
            environment: environment,
            instanceID: instanceID,
            deviceBinding: deviceBinding
        ))
    }

    private static func base64urlDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = base64.count % 4
        if pad > 0 {
            base64.append(String(repeating: "=", count: 4 - pad))
        }
        return Data(base64Encoded: base64)
    }
}

private extension Data {
    init(hexString: String) throws {
        guard hexString.count == 130, hexString.hasPrefix("04") else {
            throw EntitlementReceipt.VerificationError.unknownKeyId
        }
        let start = hexString.index(hexString.startIndex, offsetBy: 2)
        var bytes = [UInt8]()
        var index = start
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                throw EntitlementReceipt.VerificationError.unknownKeyId
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
