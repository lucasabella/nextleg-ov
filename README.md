# NextLeg

An iPhone app and Home Screen widget for your next train or bus. On the Lock Screen, a rectangular widget shows the next departure and a round one shows whether the train or bus runs late.

In Settings, pick your home and work stop by typing part of the name. The list comes from the Pi and covers every Dutch station and stop. NextLeg then shows the fastest journey between them, direct or with one change. Until you pick, it uses Blerick station and the Corridor stop in Veghel.

In Auto, the app picks the direction by location: near the home stop it shows the way to work, near the work stop the way home. When you leave that area, NextLeg assumes you boarded and follows that train or bus until you arrive. It needs location set to Always and only stores which area you left and when, on the phone. Without location, Auto shows the way to work before 12:00 and the way home after. The simulator cannot trigger these area events, so test this part on a phone.

Saved journey data is shown as stale once its `fetchedAt` time is more than 20 minutes old. The app and widget also mark cached data stale when a refresh fails.

## Ride Live Activity

Open the app and tap **Track train** or **Track bus** for a fresh journey. The Live Activity shows the selected leg, its arrival time when the service supplies one, the next connection, delay, platform, and last update time. Tap **Stop Live Activity** to dismiss it.

The ride detection feature can start the same activity with `RideActivity.start(snapshot:legIndex:)` after it identifies the boarded leg. `RideActivity.update(with:)` only updates an activity when the new response contains the same scheduled leg, so a later departure cannot replace the ride being tracked. If that leg disappears from the next-journey response, the activity becomes stale until ride-specific data is available.

The app updates the activity when it refreshes. Live Activities do not fetch data themselves. Updating one while the app is closed requires a future Pi-to-APNs push setup; this version does not send push notifications.
