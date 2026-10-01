# NextLeg

An iPhone app and Home Screen widget for your next train or bus. On the Lock Screen, a rectangular widget shows the next departure and a round one shows whether the train or bus runs late.

In Settings, pick your home and work stop by typing part of the name. The list comes from the Pi and covers every Dutch station and stop. NextLeg then shows the fastest journey between them, direct or with one change. Until you pick, it uses Blerick station and the Corridor stop in Veghel.

In Auto, the app uses location updates to pick the direction: near the home stop it shows the way to work, near the work stop the way home. Between those areas, it keeps the direction from the last stop and follows the train or bus you board. Your home can be away from the home stop: leaving the stop area only counts as boarding once the phone follows the journey that left then, within 1.5 km of the line through its stops and at least 2 km along it. Cycling or driving home from the station does not count. It needs location set to Always to check location in the background. Exact coordinates stay on the phone and are not stored or sent to the Pi. NextLeg stores which area you left, when, and when that turned out to be boarding. Without location, Auto shows the way to work before 12:00 and the way home after. The simulator cannot trigger these area events, so test this part on a phone.

With an NS API key on the Pi, a train leg also shows NS disruptions and engineering works on its route: the full text in the app, and "Disruption" or "Works" in the widgets.

Saved journey data is shown as stale once its `fetchedAt` time is more than 20 minutes old. The app and widget also mark cached data stale when a refresh fails.

## Ride Live Activity

In Auto, NextLeg uses the time you leave a stop area to find the journey you boarded, and starts tracking it once the phone follows that journey's route. It starts a Live Activity when the app is open and the Pi returns a matching journey. It updates it while location updates arrive. It ends it when you reach the other stop area within ten minutes of the expected arrival, or after you stay near that stop for three minutes. The activity shows the current leg, the full train and bus route, a progress line, delay, and platform. The progress line estimates elapsed journey time from the expected or scheduled first departure to the final arrival. iOS requires APNs to start a Live Activity while the app is in the background. To track the full journey manually, open the app and tap **Track journey** for fresh data. If location missed the ride you are on, tap **Track an earlier journey** and pick it from the journeys that already left and have not arrived yet. The app refreshes that activity when it opens and while location updates arrive. Tap **Stop Live Activity** to dismiss it.

`RideActivity.update(with:)` only updates an activity when the new response contains the same first scheduled leg, so a later departure cannot replace the ride being tracked. It advances the display through the transfer as the expected times pass.

Background location updates need location set to Always and use extra battery. The app refreshes the activity when location updates arrive; if iOS stops delivering them, it keeps the last data until another update. The timer uses the expected or scheduled departure as an estimate, since the app cannot detect the exact moment you sit down on the vehicle.
