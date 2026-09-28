import Foundation

struct JourneyService {
    func checkHealth(at serviceURL: String) async throws {
        let data = try await get(serviceURL: serviceURL, path: "/health")
        guard let health = try? JSONDecoder().decode(HealthResponse.self, from: data), health.status == "ok" else {
            throw JourneyServiceError.invalidHealthResponse
        }
    }

    func fetchJourney(at serviceURL: String, direction: JourneyDirection) async throws -> JourneySnapshot {
        let data = try await get(
            serviceURL: serviceURL,
            path: "/api/v1/journey",
            direction: direction
        )
        let snapshot: JourneySnapshot
        do {
            snapshot = try JourneyJSON.decode(data)
        } catch {
            throw JourneyServiceError.invalidJourneyResponse
        }
        guard snapshot.direction == direction else {
            throw JourneyServiceError.wrongJourneyDirection
        }
        return snapshot
    }

    private func get(serviceURL: String, path: String, direction: JourneyDirection? = nil) async throws -> Data {
        var components = try serviceComponents(serviceURL)
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        if let direction {
            components.queryItems = [URLQueryItem(name: "direction", value: direction.rawValue)]
        }
        guard let url = components.url else { throw JourneyServiceError.invalidServiceURL }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw JourneyServiceError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw JourneyServiceError.httpStatus(response.statusCode)
        }
        return data
    }

    private func serviceComponents(_ serviceURL: String) throws -> URLComponents {
        let value = serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw JourneyServiceError.invalidServiceURL
        }

        if scheme == "https" { return components }
        guard scheme == "http", isLocalHost(host) else {
            throw JourneyServiceError.httpsRequired
        }
        return components
    }

    private func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }

        if host.contains(":") {
            let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if address == "::1" { return true }
            guard let firstBlock = address.split(separator: ":").first,
                  let first = UInt16(firstBlock, radix: 16)
            else {
                return false
            }
            return first & 0xfe00 == 0xfc00 || first & 0xffc0 == 0xfe80
        }

        if !host.contains(".") { return false }

        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        let first = octets[0]
        let second = octets[1]
        return first == 10 || first == 127 || first == 169 && second == 254 ||
            first == 172 && (16...31).contains(second) || first == 192 && second == 168
    }
}

private struct HealthResponse: Decodable {
    let status: String
}

private enum JourneyServiceError: LocalizedError {
    case invalidServiceURL
    case httpsRequired
    case invalidResponse
    case invalidHealthResponse
    case invalidJourneyResponse
    case wrongJourneyDirection
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServiceURL:
            "Enter a valid service address, such as http://nextleg.local:8080."
        case .httpsRequired:
            "Use HTTPS for a service outside your local network."
        case .invalidResponse:
            "The service returned an invalid HTTP response."
        case .invalidHealthResponse:
            "Health check did not return {\"status\":\"ok\"}."
        case .invalidJourneyResponse:
            "The service returned journey data in an invalid format."
        case .wrongJourneyDirection:
            "The service returned a journey for the wrong direction."
        case .httpStatus(let status):
            "The service returned HTTP \(status)."
        }
    }
}
