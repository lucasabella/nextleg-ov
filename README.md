# NextLeg

An iPhone app and home screen widget for the next leg of your train and bus trip.

## Project structure

```text
ios/NextLeg/
  NextLeg.xcodeproj
  NextLeg/
    App/                 App entry point
    Features/Home/       Home screen
    Resources/            Asset catalog
  NextLegWidget/         WidgetKit extension
backend/                 Raspberry Pi API service
```

## Run on iPhone

Open `ios/NextLeg/NextLeg.xcodeproj` in Xcode, connect an iPhone, select it as the run destination, then press **Run**.

The app and widget currently show a small Hello World preview. Transit data and the Raspberry Pi service will be added next.
