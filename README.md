# NextLeg

An iPhone app and Home Screen widget for your next train or bus. On the Lock Screen, a rectangular widget shows the next departure and a round one shows whether the train or bus runs late.

In Auto, the app picks the direction by location: near Blerick station it shows the way to work, near the Corridor stop the way home. When you leave that area, NextLeg assumes you boarded and follows that train or bus until you arrive. It needs location set to Always and only stores which area you left and when, on the phone. Without location, Auto shows the way to work before 12:00 and the way home after. The simulator cannot trigger these area events, so test this part on a phone.

Saved journey data is shown as stale once its `fetchedAt` time is more than 20 minutes old. The app and widget also mark cached data stale when a refresh fails.
