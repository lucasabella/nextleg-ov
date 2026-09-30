# NextLeg

An iPhone app and Home Screen widget for your next train or bus. On the Lock Screen, a rectangular widget shows the next departure and a round one shows whether the train or bus runs late.

In Settings, pick your home and work stop by typing part of the name. The list comes from the Pi and covers every Dutch station and stop. NextLeg then shows the fastest journey between them, direct or with one change. Until you pick, it uses Blerick station and the Corridor stop in Veghel.

In Auto, the app uses location updates to pick the direction: near the home stop it shows the way to work, near the work stop the way home. Between those areas, it keeps the direction from the last stop and follows the train or bus you board. It needs location set to Always to check location in the background. Exact coordinates stay on the phone and are not stored or sent to the Pi. NextLeg stores which area you left and when. Without location, Auto shows the way to work before 12:00 and the way home after. The simulator cannot trigger these area events, so test this part on a phone.

Saved journey data is shown as stale once its `fetchedAt` time is more than 20 minutes old. The app and widget also mark cached data stale when a refresh fails.

## Ride Live Activity

In Auto, NextLeg uses the time you leave a stop area to find the journey you boarded. It starts a Live Activity when the app is open and the Pi returns a matching journey. It updates it while location updates arrive and ends it after you stay near the other stop for three minutes. The activity shows the current leg, the transfer, delay, platform, and a timer from the expected or scheduled first departure. iOS requires APNs to start a Live Activity while the app is in the background. To track a leg manually, open the app and tap **Track train** or **Track bus** for a fresh journey. Tap **Stop Live Activity** to dismiss it.

`RideActivity.update(with:)` only updates an activity when the new response contains the same first scheduled leg, so a later departure cannot replace the ride being tracked. It advances the display through the transfer as the expected times pass.

Background location updates need location set to Always and use extra battery. The app refreshes the activity when location updates arrive; if iOS stops delivering them, it keeps the last data until another update. The timer uses the expected or scheduled departure as an estimate, since the app cannot detect the exact moment you sit down on the vehicle.
