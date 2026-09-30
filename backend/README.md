# Raspberry Pi service

The Java service reads OpenOV's static GTFS timetable for all Dutch public transport and finds the next journey between two stops you choose, direct or with one change. Without chosen stops it uses the Blerick ↔ Corridor (Veghel) commute. It adds live delays, cancellations, and train platforms from OpenOV's realtime feeds when they have data for a trip.

The feed has no transfer walking times. A change can happen at the same place or at a stop within 400 metres, such as a station and the bus station next to it. The service uses a 10-minute minimum connection buffer and a 60-minute maximum as search heuristics. They do not confirm that a transfer is walkable or guaranteed, and they skip tight changes a planner such as NS would show.

## Run on Raspberry Pi OS

Use 64-bit Raspberry Pi OS with Java 21. Current Raspberry Pi OS is based on Debian Trixie, which provides the OpenJDK 21 package for arm64. See the [Raspberry Pi OS release notes](https://www.raspberrypi.com/documentation/computers/os.html) and [Debian package listing](https://packages.debian.org/trixie/arm64/openjdk-21-jdk).

Install Java:

```sh
sudo apt update
sudo apt install openjdk-21-jdk
java -version
```

From this repository checkout:

```sh
cd backend
mkdir -p build
javac --release 21 --add-modules jdk.httpserver -d build src/main/java/NextLegServer.java
java -Xmx384m -XX:+UseSerialGC --add-modules jdk.httpserver -cp build NextLegServer
```

The first run downloads the OpenOV schedule archive, currently about 230 MB compressed. At startup and after each update, the service reads the timetable from yesterday up to the day after tomorrow into memory, about 4 million stop times. That takes a few seconds on a laptop and longer on a Pi. After midnight it reads the saved archive again for the new days. The service checks for schedule updates every six hours and keeps the archive in `~/.nextleg` by default. OpenOV's schedule feed is CC0. The downloader uses a descriptive User-Agent, gzip, and conditional requests as requested by the [feed usage policy](https://gtfs.openov.nl/LICENSE.TXT). Check the [feed listing](https://gtfs.openov.nl/gtfs-rt/) for the current archive size.

For live data, the service fetches `trainUpdates.pb` and `tripUpdates.pb` (about 2 MB gzipped together) when a journey is requested, at most once a minute, with `If-None-Match`. It keeps only the trips that stop at places recent requests used, and reads the feeds again sooner when a request adds new places. When a feed fails, it uses the last good data for up to ten minutes, then falls back to scheduled times. OpenOV answers HTTP 429 when one address asks too often, so do not poll the feeds from other tools on the same network.

The service listens on port `8080` and all Pi network interfaces by default. `NEXTLEG_HOST`, `NEXTLEG_PORT`, and `NEXTLEG_DATA_DIR` can override the bind address, port, and cache directory. `NEXTLEG_TRANSFER_BUFFER_MINUTES` changes the minimum connection buffer, which cannot be lower than 10. `NEXTLEG_MAX_TRANSFER_WAIT_MINUTES` changes the maximum wait and cannot be lower than the minimum buffer. Defaults are 10 and 60 minutes.

Set `NS_API_KEY` to a key from the free "Ns-App" product on [apiportal.ns.nl](https://apiportal.ns.nl) to add NS disruptions and engineering works to train legs. The service reads them at most every three minutes, only when a journey has a train leg, which stays far below the free limit of 5000 requests a day. Keep the key out of the repository, for example in a systemd drop-in such as `/etc/systemd/system/nextleg.service.d/ns.conf` with `[Service]` and `Environment=NS_API_KEY=...`, readable by root only. Without a key, journeys have no notices.

The service has no authentication. Do not add a router port forward. For access away from home, see below.

## Run as a service

Run the service on boot and restart it after a crash with systemd. Java compiles the source file at startup, so an update is `git pull` followed by a restart. Replace `pi` with your user.

```sh
sudo tee /etc/systemd/system/nextleg.service >/dev/null <<EOF
[Unit]
Description=NextLeg journey service
After=network-online.target
Wants=network-online.target

[Service]
User=pi
WorkingDirectory=/home/pi/nextleg-ov/backend
ExecStart=/usr/bin/java -Xmx384m -XX:+UseSerialGC -XX:MinHeapFreeRatio=10 -XX:MaxHeapFreeRatio=30 --add-modules jdk.httpserver src/main/java/NextLegServer.java
Restart=on-failure
RestartSec=10
# Java exits with 143 on SIGTERM, which is a normal stop.
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now nextleg
journalctl -u nextleg -f
```

The timetable uses about 130 MB of heap. Reading a new one while the old one still serves requests peaks at about 270 MB, so 384 MB of heap is enough. The serial collector and heap ratios give unused memory back, which keeps the process around 350 MB.

## Reach it away from home

[Tailscale Funnel](https://tailscale.com/kb/1223/funnel) can publish the service over HTTPS without a port forward. The phone does not need Tailscale. Put the service behind a long random path, because anyone with the full URL can read your journey:

```sh
SECRET=$(openssl rand -hex 16)
sudo tailscale funnel --bg --https=10000 --set-path=/$SECRET http://127.0.0.1:8080
tailscale funnel status
```

In NextLeg, enter the port `10000` address followed by the secret path, such as `https://raspberrypi.example.ts.net:10000/<secret>`. Treat it like a password. Other paths return 404. Remove it with `sudo tailscale funnel --https=10000 --set-path=/$SECRET off`.

Find the Pi's local address with `hostname -I`. Check the service on the Pi:

```sh
curl http://127.0.0.1:8080/health
curl 'http://127.0.0.1:8080/api/v1/journey?direction=to_veghel'
curl 'http://127.0.0.1:8080/api/v1/journey?direction=to_blerick'
```

In NextLeg, enter `http://<pi-address>:8080` while the iPhone is on the same Wi-Fi network. On first startup, `/health` responds before the timetable is read. Journey and stop requests return `503` until it is available. If an update fails after a schedule was cached, the service returns that schedule marked stale.

## Endpoints

- `GET /health` returns `{"status":"ok"}`.
- `GET /api/v1/stops?query=veghel corr` returns up to 15 places whose name has every typed word at the start of one of its words, ignoring case and accents: `{"stops":[{"id":"Veghel, Corridor|51.600|5.519","name":"Veghel, Corridor","latitude":51.600224,"longitude":5.519167,"modes":["bus"]}]}`. A place groups stops with the same name within a kilometre, such as the platforms of a station or both sides of a road. Train stations come first. OpenOV renumbers stops between feeds, so an id is the name with a rounded position, and it still finds the nearest place with that name within two kilometres after an update.
- `GET /api/v1/journey?direction=to_veghel` and `direction=to_blerick` return the next journey in the shared JSON model: one leg when a direct ride is fastest, else two. Add `from` and `to` with place ids from `/api/v1/stops` to choose the stops. Without them, `to_veghel` goes from Blerick to Corridor and `to_blerick` back. `direction` stays required and is returned as is. Between journeys that arrive at the same time, the one that leaves later wins. The search uses expected times, so a delayed train that is still to come counts, and cancelled trips are skipped. If no connection is found in the available feed dates, the response has an empty `legs` array. `fetchedAt` is when the Pi built the response. `freshness` is `stale` when the schedule could not be refreshed.
- Every leg has `scheduledDeparture` and `scheduledArrival`. Legs with live data have status `on_time` or `delayed`, and `sourceUpdatedAt`. `platform` is the live track when known, else the planned one.
- With `NS_API_KEY` set, a train leg can have `notices`: NS disruptions (`type` `disruption`) and engineering works (`maintenance`) that affect at least two of its stations, or the only one named, while the leg runs. Each has a `title` and, when NS gives them, `situation`, `expectedDuration`, and `alternative`, in Dutch as NS writes them. `expectedDeparture`, `delaySeconds`, and `expectedArrival` appear from one minute of difference. Legs without live data have status `scheduled`.
- Add `departure=07:10` (local time, `HH:mm`) to get the first connection whose first leg leaves at or after that time. If today's has already left, the response uses the next day's.
- Add `boardedAt=2026-09-30T05:10:00Z` (ISO 8601) when the phone left its start area to get the journey it is on: the first leg that departed closest to two minutes before that moment, from 30 minutes before to 5 minutes after it. Without a match, the response is the normal next journey. The app sends it; the Pi never receives your location.
