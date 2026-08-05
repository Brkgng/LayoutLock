import Foundation

struct LicenseValidationRequest: Encodable, Equatable {
    let licenseKey: String
    let appVersion: String
    let deviceLabel: String
    let deviceIdentifier: String
    let instanceID: String?
}

struct LicenseValidationResult: Decodable, Equatable {
    let status: EntitlementValidationStatus
    let validatedAt: Date
    let customerID: String?
    let productID: String?
    let instanceID: String?
    let message: String?
    let receipt: String?
}

enum LicenseActivationClientError: LocalizedError, Equatable {
    case notConfigured
    case invalidResponse
    case invalidProduct
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Pro activation is not configured yet."
        case .invalidResponse:
            return "The license server returned an invalid response."
        case .invalidProduct:
            return "This license is not for LayoutLock Pro."
        case let .serverMessage(message):
            return message
        }
    }
}

extension LicenseValidationResult {
    func validatingProductID(_ expectedProductID: String) throws -> LicenseValidationResult {
        guard status != .active || productID == expectedProductID else {
            throw LicenseActivationClientError.invalidProduct
        }

        return self
    }
}

protocol LicenseActivationClienting {
    func activate(_ request: LicenseValidationRequest) async throws -> LicenseValidationResult
    func validate(_ request: LicenseValidationRequest) async throws -> LicenseValidationResult
    func deactivate(_ request: LicenseValidationRequest) async throws -> LicenseValidationResult
}

struct LicenseActivationClient: LicenseActivationClienting {
    private struct ServerError: Decodable {
        let message: String?
    }

    private let baseURLProvider: () -> URL?
    private let expectedProductIDProvider: () -> String?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        baseURLProvider: @escaping () -> URL? = { LayoutLockProConfiguration.proxyBaseURL },
        expectedProductIDProvider: @escaping () -> String? = { LayoutLockProConfiguration.productID },
        session: URLSession = .shared
    ) {
        self.baseURLProvider = baseURLProvider
        self.expectedProductIDProvider = expectedProductIDProvider
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func activate(_ request: LicenseValidationRequest) async throws -> LicenseValidationResult {
        try await send(request, path: "v1/layoutlock/licenses/activate")
    }

    func validate(_ request: LicenseValidationRequest) async throws -> LicenseValidationResult {
        try await send(request, path: "v1/layoutlock/licenses/validate")
    }

    func deactivate(_ request: LicenseValidationRequest) async throws -> LicenseValidationResult {
        try await send(request, path: "v1/layoutlock/licenses/deactivate")
    }

    private func send(
        _ request: LicenseValidationRequest,
        path: String
    ) async throws -> LicenseValidationResult {
        guard let baseURL = baseURLProvider(),
              let expectedProductID = expectedProductIDProvider() else {
            throw LicenseActivationClientError.notConfigured
        }

        let endpointURL = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseActivationClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let serverError = try? decoder.decode(ServerError.self, from: data),
               let message = serverError.message?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                throw LicenseActivationClientError.serverMessage(message)
            }

            throw LicenseActivationClientError.invalidResponse
        }

        return try decoder
            .decode(LicenseValidationResult.self, from: data)
            .validatingProductID(expectedProductID)
    }
}
