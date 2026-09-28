# Raspberry Pi service

The Java service reads OpenOV's static GTFS timetable and serves the next connected train and bus departures for the Blerick ↔ Corridor commute. This version returns scheduled times only. It does not yet include live delay or cancellation updates.

The feed has no transfer walking times. The service uses a 10-minute minimum connection buffer and a 60-minute maximum as search heuristics. They do not confirm that a transfer is walkable or guaranteed.

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
java --add-modules jdk.httpserver -cp build NextLegServer
```

The first run downloads the OpenOV schedule archive, currently about 230 MB compressed, and scans its large stop-time table. Processing time depends on the Pi and storage. The service checks for schedule updates every six hours and keeps the archive and a small route index in `~/.nextleg` by default. OpenOV's schedule feed is CC0. The downloader uses a descriptive User-Agent, gzip, and conditional requests as requested by the [feed usage policy](https://gtfs.openov.nl/LICENSE.TXT). Check the [feed listing](https://gtfs.openov.nl/gtfs-rt/) for the current archive size.

The service listens on port `8080` and all Pi network interfaces by default. `NEXTLEG_HOST`, `NEXTLEG_PORT`, and `NEXTLEG_DATA_DIR` can override the bind address, port, and cache directory. `NEXTLEG_TRANSFER_BUFFER_MINUTES` changes the minimum connection buffer, which cannot be lower than 10. `NEXTLEG_MAX_TRANSFER_WAIT_MINUTES` changes the maximum wait and cannot be lower than the minimum buffer. Defaults are 10 and 60 minutes.

Keep the service on your trusted home network. Do not add a router port forward. Remote access is not configured. The service has no authentication.

Find the Pi's local address with `hostname -I`. Check the service on the Pi:

```sh
curl http://127.0.0.1:8080/health
curl 'http://127.0.0.1:8080/api/v1/journey?direction=to_veghel'
curl 'http://127.0.0.1:8080/api/v1/journey?direction=to_blerick'
```

In NextLeg, enter `http://<pi-address>:8080` while the iPhone is on the same Wi-Fi network. On first startup, `/health` may respond before the schedule download finishes. Journey requests return `503` until a schedule is available. If an update fails after a schedule was cached, the service returns that schedule marked stale.

## Endpoints

- `GET /health` returns `{"status":"ok"}`.
- `GET /api/v1/journey?direction=to_veghel` and `direction=to_blerick` return the next scheduled two-leg connection in the shared JSON model. If no connection is found in the available feed dates, the response has an empty `legs` array. Static responses omit real-time expected times and platform values.
