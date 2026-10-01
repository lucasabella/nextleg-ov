import ActivityKit
import Foundation
import UIKit

enum RideActivity {
    static var isActive: Bool {
        !Activity<RideActivityAttributes>.activities.isEmpty
    }

    static var trackedDirection: JourneyDirection? {
        Activity<RideActivityAttributes>.activities.first?.attributes.direction
    }

    static var trackedDeparture: Date? {
        Activity<RideActivityAttributes>.activities.first?.attributes.scheduledDeparture
    }

    static func start(snapshot: JourneySnapshot, legIndex: Int) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw RideActivityError.disabled
        }
        guard snapshot.freshness == .fresh, Date.now.timeIntervalSince(snapshot.fetchedAt) < 20 * 60,
              snapshot.legs.indices.contains(legIndex),
              snapshot.legs[legIndex].status != .cancelled,
              snapshot.legs[legIndex].status != .skipped else {
            throw RideActivityError.unavailable
        }

        await end()
        let leg = snapshot.legs[legIndex]
        let attributes = RideActivityAttributes(
            direction: snapshot.direction,
            legIndex: legIndex,
            scheduledDeparture: leg.scheduledDeparture
        )
        // A journey that already left can be past its first leg.
        let content = ActivityContent(
            state: state(snapshot: snapshot, legIndex: currentLegIndex(in: snapshot.legs, startingAt: legIndex, at: .now)),
            staleDate: snapshot.fetchedAt.addingTimeInterval(20 * 60)
        )
        _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    static func startAutomatically(snapshot: JourneySnapshot, legIndex: Int) async throws {
        guard UIApplication.shared.applicationState == .active else { return }
        try await start(snapshot: snapshot, legIndex: legIndex)
    }

    static func update(with snapshot: JourneySnapshot) async {
        for activity in Activity<RideActivityAttributes>.activities {
            let attributes = activity.attributes
            guard attributes.direction == snapshot.direction,
                  snapshot.legs.indices.contains(attributes.legIndex),
                  snapshot.legs[attributes.legIndex].scheduledDeparture == attributes.scheduledDeparture else { continue }
            let index = currentLegIndex(in: snapshot.legs, startingAt: attributes.legIndex, at: .now)
            await activity.update(ActivityContent(
                state: state(snapshot: snapshot, legIndex: index,
                             journeyStartedAt: activity.content.state.journeyStartedAt),
                staleDate: snapshot.fetchedAt.addingTimeInterval(20 * 60)
            ))
        }
    }

    static func markStale(direction: JourneyDirection) async {
        for activity in Activity<RideActivityAttributes>.activities where activity.attributes.direction == direction {
            let old = activity.content.state
            let stale = RideActivityAttributes.ContentState(
                mode: old.mode,
                destination: old.destination,
                departure: old.departure,
                arrival: old.arrival,
                status: old.status,
                delaySeconds: old.delaySeconds,
                platform: old.platform,
                nextMode: old.nextMode,
                nextDeparture: old.nextDeparture,
                nextDestination: old.nextDestination,
                journeyStartedAt: old.journeyStartedAt,
                journeyArrivalAt: old.journeyArrivalAt,
                journeyLegs: old.journeyLegs,
                fetchedAt: old.fetchedAt,
                isStale: true
            )
            await activity.update(ActivityContent(state: stale, staleDate: .now))
        }
    }

    static func end() async {
        for activity in Activity<RideActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func state(snapshot: JourneySnapshot, legIndex: Int,
                              journeyStartedAt: Date? = nil) -> RideActivityAttributes.ContentState {
        let leg = snapshot.legs[legIndex]
        let next = snapshot.legs.indices.contains(legIndex + 1) ? snapshot.legs[legIndex + 1] : nil
        return RideActivityAttributes.ContentState(
            mode: leg.mode,
            destination: leg.destination,
            departure: leg.expectedDeparture ?? leg.scheduledDeparture,
            arrival: leg.expectedArrival ?? leg.scheduledArrival,
            status: leg.status,
            delaySeconds: leg.delaySeconds,
            platform: leg.platform,
            nextMode: next?.mode,
            nextDeparture: next?.expectedDeparture ?? next?.scheduledDeparture,
            nextDestination: next?.destination,
            journeyStartedAt: journeyStartedAt ?? snapshot.legs.first?.expectedDeparture ?? snapshot.legs.first?.scheduledDeparture,
            journeyArrivalAt: snapshot.legs.last?.expectedArrival ?? snapshot.legs.last?.scheduledArrival,
            journeyLegs: snapshot.legs.map { leg in
                RideActivityAttributes.LegState(
                    mode: leg.mode,
                    origin: leg.origin,
                    destination: leg.destination,
                    departure: leg.expectedDeparture ?? leg.scheduledDeparture,
                    arrival: leg.expectedArrival ?? leg.scheduledArrival,
                    status: leg.status,
                    delaySeconds: leg.delaySeconds,
                    platform: leg.platform
                )
            },
            fetchedAt: snapshot.fetchedAt,
            isStale: snapshot.freshness != .fresh || Date.now.timeIntervalSince(snapshot.fetchedAt) >= 20 * 60
        )
    }

    private static func currentLegIndex(in legs: [JourneyLeg], startingAt index: Int, at date: Date) -> Int {
        for current in index..<legs.count {
            let leg = legs[current]
            if date < leg.departureTime { return current }
            let arrival = leg.arrivalTime ?? legs.dropFirst(current + 1).first?.departureTime
            if let arrival, date < arrival { return current }
        }
        return legs.count - 1
    }

}

private enum RideActivityError: LocalizedError {
    case disabled
    case unavailable

    var errorDescription: String? {
        switch self {
        case .disabled: "Enable Live Activities for NextLeg in iPhone Settings."
        case .unavailable: "Refresh the journey before tracking this ride."
        }
    }
}
