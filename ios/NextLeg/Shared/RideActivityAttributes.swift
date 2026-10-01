import ActivityKit
import Foundation

nonisolated struct RideActivityAttributes: ActivityAttributes {
    nonisolated struct LegState: Codable, Hashable {
        let mode: Mode
        let origin: String
        let destination: String
        let departure: Date
        let arrival: Date?
        let status: JourneyLegStatus
        let delaySeconds: Int?
        let platform: String?
    }

    nonisolated struct ContentState: Codable, Hashable {
        let mode: Mode
        let destination: String
        let departure: Date
        let arrival: Date?
        let status: JourneyLegStatus
        let delaySeconds: Int?
        let platform: String?
        let nextMode: Mode?
        let nextDeparture: Date?
        let nextDestination: String?
        let journeyStartedAt: Date?
        let journeyArrivalAt: Date?
        let journeyLegs: [LegState]?
        let fetchedAt: Date
        let isStale: Bool
    }

    let direction: JourneyDirection
    let legIndex: Int
    let scheduledDeparture: Date
}
