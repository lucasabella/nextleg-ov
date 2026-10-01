import Foundation

struct JourneyService {
    func checkHealth(at serviceURL: String) async throws {
        let data = try await get(serviceURL: serviceURL, path: "/health")
        guard let health = try? JSONDecoder().decode(HealthResponse.self, from: data), health.status == "ok" else {
            throw JourneyServiceError.invalidHealthResponse
        }
    }

    func fetchJourney(at serviceURL: String, direction: JourneyDirection, usualDeparture: String?,
                      boardedAt: Date?) async throws -> JourneySnapshot {
        let stops = JourneyPreferences.stops(for: direction)
        var query = [
            URLQueryItem(name: "direction", value: direction.rawValue),
            URLQueryItem(name: "from", value: stops.from.id),
            URLQueryItem(name: "to", value: stops.to.id),
        ]
        if let usualDeparture {
            query.append(URLQueryItem(name: "departure", value: usualDeparture))
        }
        if let boardedAt {
            query.append(URLQueryItem(name: "boardedAt", value: ISO8601DateFormatter().string(from: boardedAt)))
        }
        let data = try await get(serviceURL: serviceURL, path: "/api/v1/journey", query: query)
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

    /// Journeys that already left the first stop and have not arrived yet, latest departure first.
    func fetchUnderway(at serviceURL: String, direction: JourneyDirection) async throws -> [JourneySnapshot] {
        let stops = JourneyPreferences.stops(for: direction)
        let data = try await get(serviceURL: serviceURL, path: "/api/v1/underway", query: [
            URLQueryItem(name: "direction", value: direction.rawValue),
            URLQueryItem(name: "from", value: stops.from.id),
            URLQueryItem(name: "to", value: stops.to.id),
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(UnderwayResponse.self, from: data),
              response.journeys.allSatisfy({ $0.direction == direction }) else {
            throw JourneyServiceError.invalidJourneyResponse
        }
        return response.journeys
    }

    /// Stations and stops whose name matches what was typed, best match first.
    func searchStops(at serviceURL: String, query: String) async throws -> [Stop] {
        let data: Data
        do {
            data = try await get(serviceURL: serviceURL, path: "/api/v1/stops", query: [URLQueryItem(name: "query", value: query)])
        } catch JourneyServiceError.httpStatus(let status) where status == 404 {
            throw JourneyServiceError.stopSearchUnavailable
        }
        guard let response = try? JSONDecoder().decode(StopsResponse.self, from: data) else {
            throw JourneyServiceError.invalidStopsResponse
        }
        return response.stops
    }

    private func get(serviceURL: String, path: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = try serviceComponents(serviceURL)
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        if !query.isEmpty {
            components.queryItems = query
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

private struct StopsResponse: Decodable {
    let stops: [Stop]
}

private struct UnderwayResponse: Decodable {
    let journeys: [JourneySnapshot]
}

private enum JourneyServiceError: LocalizedError {
    case invalidServiceURL
    case httpsRequired
    case invalidResponse
    case invalidHealthResponse
    case invalidJourneyResponse
    case wrongJourneyDirection
    case stopSearchUnavailable
    case invalidStopsResponse
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
        case .stopSearchUnavailable:
            "This service cannot search stops yet. Update the NextLeg service on the Pi."
        case .invalidStopsResponse:
            "The service returned stops in an invalid format."
        case .httpStatus(let status):
            "The service returned HTTP \(status)."
        }
    }
}
