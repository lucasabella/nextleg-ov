# Raspberry Pi service

This branch serves fictional sample journeys so the iPhone app can connect to the Pi. It does not provide live departure information. Do not use its sample times to travel.

## Run on Raspberry Pi OS

Use 64-bit Raspberry Pi OS with Java 21. Current Raspberry Pi OS is based on Debian Trixie, which provides the OpenJDK 21 package for arm64. See the [Raspberry Pi OS release notes](https://www.raspberrypi.com/documentation/computers/os.html) and [Debian package listing](https://packages.debian.org/trixie/arm64/openjdk-21-jdk).

Install it with:

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

The service listens on port `8080` and all Pi network interfaces by default. `NEXTLEG_HOST` and `NEXTLEG_PORT` can override the bind address and port. Keep the service on your trusted home network. Do not add a router port forward. Remote access is not configured yet.

Find the Pi's local address with `hostname -I`. Check the service on the Pi:

```sh
curl http://127.0.0.1:8080/health
curl 'http://127.0.0.1:8080/api/v1/journey?direction=to_veghel'
```

In NextLeg, enter `http://<pi-address>:8080` while the iPhone is on the same Wi-Fi network. The service has no authentication, so do not expose it beyond that network.

## Endpoints

- `GET /health` returns `{"status":"ok"}`.
- `GET /api/v1/journey?direction=to_veghel` and `direction=to_blerick` return the shared journey JSON model with `freshness: "sample"`.
