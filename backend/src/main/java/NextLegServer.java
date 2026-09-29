import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.URLDecoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.EnumMap;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.TreeMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.zip.GZIPInputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

public final class NextLegServer {
    private static final ZoneId ZONE = ZoneId.of("Europe/Amsterdam");
    private static final Duration FEED_CHECK_INTERVAL = Duration.ofHours(6);
    private static final Duration RETRY_INTERVAL = Duration.ofMinutes(30);
    private static final URI DEFAULT_FEED_URI = URI.create("https://gtfs.openov.nl/gtfs-rt/gtfs-openov-nl.zip");
    private static final DateTimeFormatter GTFS_DATE = DateTimeFormatter.BASIC_ISO_DATE;
    private static final DateTimeFormatter ISO_INSTANT = DateTimeFormatter.ISO_INSTANT;
    private static final List<PathSpec> PATHS = List.of(
            new PathSpec(PathKey.TO_VEGHEL_TRAIN, "IC3500", "2992392", "4001925", "train"),
            new PathSpec(PathKey.TO_VEGHEL_BUS, "305", "4120192", "4120209", "bus"),
            new PathSpec(PathKey.TO_BLERICK_BUS_306, "306", "4120206", "4168164", "bus"),
            new PathSpec(PathKey.TO_BLERICK_TRAIN_DEN_BOSCH, "IC3500", "4001954", "2992391", "train"),
            new PathSpec(PathKey.TO_BLERICK_BUS_305, "305", "4120206", "4120193", "bus"),
            new PathSpec(PathKey.TO_BLERICK_TRAIN_EINDHOVEN, "IC3500", "4001916", "2992391", "train")
    );

    private NextLegServer() {}

    public static void main(String[] args) throws IOException {
        String host = System.getenv().getOrDefault("NEXTLEG_HOST", "0.0.0.0");
        int port = Integer.parseInt(System.getenv().getOrDefault("NEXTLEG_PORT", "8080"));
        int transferBufferMinutes = Integer.parseInt(System.getenv().getOrDefault("NEXTLEG_TRANSFER_BUFFER_MINUTES", "10"));
        int maxTransferWaitMinutes = Integer.parseInt(System.getenv().getOrDefault("NEXTLEG_MAX_TRANSFER_WAIT_MINUTES", "60"));
        if (transferBufferMinutes < 10 || maxTransferWaitMinutes < transferBufferMinutes) {
            throw new IllegalArgumentException("Transfer buffer must be at least 10 minutes and max wait must be no smaller.");
        }

        String archiveOverride = System.getenv("NEXTLEG_GTFS_ARCHIVE");
        Path dataDirectory = Path.of(System.getenv().getOrDefault(
                "NEXTLEG_DATA_DIR", Path.of(System.getProperty("user.home"), ".nextleg").toString()));
        Path archive = archiveOverride == null ? dataDirectory.resolve("openov-gtfs.zip") : Path.of(archiveOverride);
        URI feedUri = URI.create(System.getenv().getOrDefault("NEXTLEG_GTFS_URL", DEFAULT_FEED_URI.toString()));
        ScheduleRepository schedules = new ScheduleRepository(dataDirectory, archive, feedUri, archiveOverride != null);
        schedules.loadCache();
        RealtimeFeeds realtime = new RealtimeFeeds();

        HttpServer server = HttpServer.create(new InetSocketAddress(host, port), 0);
        server.createContext("/", exchange -> handle(exchange, schedules, realtime, transferBufferMinutes, maxTransferWaitMinutes));
        server.start();

        ScheduledExecutorService refresh = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "openov-schedule-refresh");
            thread.setDaemon(true);
            return thread;
        });
        refresh.scheduleWithFixedDelay(schedules::refreshIfDue, 0, 15, TimeUnit.MINUTES);
        System.out.println("NextLeg service listening on " + host + ":" + port
                + "; transfer buffer is a configurable heuristic, not GTFS walking time (" + transferBufferMinutes
                + " to " + maxTransferWaitMinutes + " minutes).");
    }

    private static void handle(HttpExchange exchange, ScheduleRepository schedules, RealtimeFeeds realtime,
                               int transferBufferMinutes, int maxTransferWaitMinutes) throws IOException {
        String path = exchange.getRequestURI().getPath();
        if (path.equals("/health")) {
            if (!exchange.getRequestMethod().equals("GET")) {
                send(exchange, 405, "{\"error\":\"Method not allowed. Use GET.\"}");
                return;
            }
            send(exchange, 200, "{\"status\":\"ok\"}");
            return;
        }
        if (!path.equals("/api/v1/journey")) {
            send(exchange, 404, "{\"error\":\"Not found.\"}");
            return;
        }
        if (!exchange.getRequestMethod().equals("GET")) {
            send(exchange, 405, "{\"error\":\"Method not allowed. Use GET.\"}");
            return;
        }

        String direction;
        LocalTime usualDeparture;
        try {
            String query = exchange.getRequestURI().getRawQuery();
            direction = queryParameter(query, "direction");
            if (direction == null || direction.isBlank()) {
                throw new IllegalArgumentException("Missing required query parameter: direction.");
            }
            usualDeparture = requestedDeparture(queryParameter(query, "departure"));
        } catch (IllegalArgumentException exception) {
            send(exchange, 400, jsonError(exception.getMessage()));
            return;
        }
        if (!direction.equals("to_veghel") && !direction.equals("to_blerick")) {
            send(exchange, 400, "{\"error\":\"Invalid direction. Use to_veghel or to_blerick.\"}");
            return;
        }

        FeedState state = schedules.state();
        if (state == null || state.data() == null) {
            send(exchange, 503, "{\"error\":\"OpenOV schedule feed is unavailable and no cached schedule is available.\"}");
            return;
        }
        Instant now = Instant.now();
        Map<String, TripUpdate> updates = realtime.current(state.data().tripIds(), now);
        JourneyChoice choice = usualDeparture == null
                ? findNextJourney(state.data(), updates, direction, now, transferBufferMinutes, maxTransferWaitMinutes)
                : findUsualJourney(state.data(), updates, direction, usualDeparture, now, transferBufferMinutes, maxTransferWaitMinutes);
        send(exchange, 200, journeyJson(direction, choice, state, now));
    }

    /** The first journey leaving at or after the usual time. Once today's has left, it looks at the next days. */
    private static JourneyChoice findUsualJourney(ScheduleData data, Map<String, TripUpdate> updates, String direction,
                                                  LocalTime usualDeparture, Instant now, int bufferMinutes, int maxWaitMinutes) {
        LocalDate today = now.atZone(ZONE).toLocalDate();
        for (int day = 0; day < 7; day++) {
            Instant usual = today.plusDays(day).atTime(usualDeparture).atZone(ZONE).toInstant();
            JourneyChoice choice = findNextJourney(data, updates, direction, usual, bufferMinutes, maxWaitMinutes);
            if (choice != null && choice.first().departure().isAfter(now)) return choice;
        }
        return null;
    }

    private static JourneyChoice findNextJourney(ScheduleData data, Map<String, TripUpdate> updates, String direction,
                                                 Instant earliest, int bufferMinutes, int maxWaitMinutes) {
        Map<PathKey, List<LegInstance>> instances = withRealtime(data.instances(earliest.atZone(ZONE).toLocalDate()), updates);
        if (direction.equals("to_veghel")) {
            return choose(instances.get(PathKey.TO_VEGHEL_TRAIN), instances.get(PathKey.TO_VEGHEL_BUS),
                    earliest, bufferMinutes, maxWaitMinutes);
        }
        JourneyChoice viaDenBosch = choose(instances.get(PathKey.TO_BLERICK_BUS_306),
                instances.get(PathKey.TO_BLERICK_TRAIN_DEN_BOSCH), earliest, bufferMinutes, maxWaitMinutes);
        JourneyChoice viaEindhoven = choose(instances.get(PathKey.TO_BLERICK_BUS_305),
                instances.get(PathKey.TO_BLERICK_TRAIN_EINDHOVEN), earliest, bufferMinutes, maxWaitMinutes);
        return earlier(viaDenBosch, viaEindhoven);
    }

    /**
     * Moves each leg to its expected times when the realtime feed has them, so the journey search uses them too.
     * Cancelled trips and skipped stops are dropped. Legs without realtime keep their scheduled times.
     */
    private static Map<PathKey, List<LegInstance>> withRealtime(Map<PathKey, List<LegInstance>> instances,
                                                                Map<String, TripUpdate> updates) {
        Map<PathKey, List<LegInstance>> result = new EnumMap<>(PathKey.class);
        for (var entry : instances.entrySet()) {
            PathSpec spec = pathSpec(entry.getKey());
            List<LegInstance> legs = new ArrayList<>();
            for (LegInstance leg : entry.getValue()) {
                TripUpdate update = updates.get(leg.tripId() + "|" + GTFS_DATE.format(leg.serviceDate()));
                StopUpdate from = update == null ? null : update.stops().get(spec.fromStop());
                StopUpdate to = update == null ? null : update.stops().get(spec.toStop());
                if (update != null && (update.cancelled() || from != null && from.skipped() || to != null && to.skipped())) continue;
                if ((from == null || from.departureDelay() == null && from.platform() == null)
                        && (to == null || to.arrivalDelay() == null)) {
                    legs.add(leg);
                    continue;
                }
                Integer delay = from == null ? null : from.departureDelay();
                int arrivalDelay = to == null || to.arrivalDelay() == null ? (delay == null ? 0 : delay) : to.arrivalDelay();
                legs.add(new LegInstance(leg.path(), leg.tripId(), leg.serviceDate(), leg.scheduledDeparture(),
                        leg.scheduledDeparture().plusSeconds(delay == null ? 0 : delay), leg.arrival().plusSeconds(arrivalDelay),
                        new Live(delay, from == null ? null : from.platform(), update.updatedAt())));
            }
            result.put(entry.getKey(), legs);
        }
        return result;
    }

    private static JourneyChoice choose(List<LegInstance> firstLegs, List<LegInstance> secondLegs,
                                        Instant earliest, int bufferMinutes, int maxWaitMinutes) {
        JourneyChoice best = null;
        if (firstLegs == null || secondLegs == null) return null;
        for (LegInstance first : firstLegs) {
            if (first.departure().isBefore(earliest)) continue;
            Instant earliestConnection = first.arrival().plusSeconds(bufferMinutes * 60L);
            Instant latestConnection = first.arrival().plusSeconds(maxWaitMinutes * 60L);
            for (LegInstance second : secondLegs) {
                if (second.departure().isBefore(earliestConnection) || second.departure().isAfter(latestConnection)) continue;
                JourneyChoice candidate = new JourneyChoice(first, second);
                if (best == null || compare(candidate, best) < 0) best = candidate;
            }
        }
        return best;
    }

    private static JourneyChoice earlier(JourneyChoice first, JourneyChoice second) {
        if (first == null) return second;
        if (second == null) return first;
        return compare(first, second) <= 0 ? first : second;
    }

    private static int compare(JourneyChoice first, JourneyChoice second) {
        int departure = first.first().departure().compareTo(second.first().departure());
        return departure != 0 ? departure : first.second().departure().compareTo(second.second().departure());
    }

    private static String journeyJson(String direction, JourneyChoice choice, FeedState state, Instant now) {
        String start = "{\"direction\":\"" + direction + "\",\"fetchedAt\":\"" + ISO_INSTANT.format(now)
                + "\",\"freshness\":\"" + (state.stale() ? "stale" : "fresh") + "\",\"legs\":[";
        if (choice == null) return start + "]}";
        ScheduleData data = state.data();
        PathSpec firstSpec = pathSpec(choice.first().path());
        PathSpec secondSpec = pathSpec(choice.second().path());
        return start + legJson(firstSpec, choice.first(), data) + "," + legJson(secondSpec, choice.second(), data) + "]}";
    }

    private static String legJson(PathSpec spec, LegInstance instance, ScheduleData data) {
        String origin = data.stopNames().getOrDefault(spec.fromStop(), spec.fromStop());
        String destination = data.stopNames().getOrDefault(spec.toStop(), spec.toStop());
        StringBuilder json = new StringBuilder("{\"mode\":\"" + spec.mode() + "\",\"origin\":\"" + jsonEscape(origin)
                + "\",\"destination\":\"" + jsonEscape(destination) + "\",\"scheduledDeparture\":\""
                + ISO_INSTANT.format(instance.scheduledDeparture()) + "\"");
        Live live = instance.live();
        if (live == null) return json.append(",\"status\":\"scheduled\"}").toString();
        // Differences under a minute count as on time, like departure boards do.
        if (live.delaySeconds() != null && Math.abs(live.delaySeconds()) >= 60) {
            json.append(",\"expectedDeparture\":\"").append(ISO_INSTANT.format(instance.departure()))
                    .append("\",\"delaySeconds\":").append(live.delaySeconds());
        }
        json.append(",\"status\":\"").append(live.delaySeconds() == null ? "scheduled"
                : live.delaySeconds() >= 60 ? "delayed" : "on_time").append('"');
        if (live.platform() != null) json.append(",\"platform\":\"").append(jsonEscape(live.platform())).append('"');
        if (live.updatedAt() != null) json.append(",\"sourceUpdatedAt\":\"").append(ISO_INSTANT.format(live.updatedAt())).append('"');
        return json.append('}').toString();
    }

    private static PathSpec pathSpec(PathKey key) {
        return PATHS.stream().filter(path -> path.key() == key).findFirst().orElseThrow();
    }

    private static LocalTime requestedDeparture(String departure) {
        if (departure == null) return null;
        try {
            return LocalTime.parse(departure);
        } catch (DateTimeParseException exception) {
            throw new IllegalArgumentException("Invalid departure. Use HH:mm, such as 07:10.");
        }
    }

    private static String queryParameter(String query, String name) {
        if (query == null || query.isEmpty()) return null;
        String result = null;
        for (String pair : query.split("&")) {
            int separator = pair.indexOf('=');
            String rawKey = separator < 0 ? pair : pair.substring(0, separator);
            String rawValue = separator < 0 ? "" : pair.substring(separator + 1);
            String key;
            String value;
            try {
                key = URLDecoder.decode(rawKey, StandardCharsets.UTF_8);
                value = URLDecoder.decode(rawValue, StandardCharsets.UTF_8);
            } catch (IllegalArgumentException exception) {
                throw new IllegalArgumentException("Invalid query encoding.");
            }
            if (key.equals(name)) {
                if (result != null) throw new IllegalArgumentException("Use exactly one " + name + " query parameter.");
                result = value;
            }
        }
        return result;
    }

    private static String jsonError(String message) {
        return "{\"error\":\"" + jsonEscape(message) + "\"}";
    }

    private static String jsonEscape(String value) {
        StringBuilder escaped = new StringBuilder(value.length());
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            switch (character) {
                case '"' -> escaped.append("\\\"");
                case '\\' -> escaped.append("\\\\");
                case '\b' -> escaped.append("\\b");
                case '\f' -> escaped.append("\\f");
                case '\n' -> escaped.append("\\n");
                case '\r' -> escaped.append("\\r");
                case '\t' -> escaped.append("\\t");
                default -> {
                    if (character < 0x20) {
                        escaped.append("\\u00");
                        escaped.append("0123456789abcdef".charAt(character >>> 4));
                        escaped.append("0123456789abcdef".charAt(character & 0x0f));
                    } else {
                        escaped.append(character);
                    }
                }
            }
        }
        return escaped.toString();
    }

    private static void send(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.getResponseHeaders().set("Cache-Control", "no-store");
        exchange.sendResponseHeaders(status, bytes.length);
        try (var output = exchange.getResponseBody()) {
            output.write(bytes);
        }
    }

    private enum PathKey {
        TO_VEGHEL_TRAIN,
        TO_VEGHEL_BUS,
        TO_BLERICK_BUS_306,
        TO_BLERICK_TRAIN_DEN_BOSCH,
        TO_BLERICK_BUS_305,
        TO_BLERICK_TRAIN_EINDHOVEN
    }

    private record PathSpec(PathKey key, String routePattern, String fromStop, String toStop, String mode) {}
    private record TripMeta(String routePattern, String serviceId) {}
    private record StopTime(String stopId, int sequence, String arrival, String departure) {}
    private record ScheduledLeg(PathKey path, String serviceId, String tripId, String departure, String arrival) {}
    /** One dated leg. Departure and arrival are the expected times when realtime data is known, else scheduled. */
    private record LegInstance(PathKey path, String tripId, LocalDate serviceDate, Instant scheduledDeparture,
                               Instant departure, Instant arrival, Live live) {}
    private record Live(Integer delaySeconds, String platform, Instant updatedAt) {}
    private record StopUpdate(Integer arrivalDelay, Integer departureDelay, boolean skipped, String platform) {}
    private record TripUpdate(boolean cancelled, Map<String, StopUpdate> stops, Instant updatedAt) {}
    private record JourneyChoice(LegInstance first, LegInstance second) {}
    private record FeedState(ScheduleData data, Instant fetchedAt, boolean stale) {}

    private static final class ScheduleData {
        private final Map<PathKey, List<ScheduledLeg>> legs;
        private final Map<LocalDate, Set<String>> activeServices;
        private final Map<String, String> stopNames;
        private final Set<String> tripIds = new HashSet<>();

        private ScheduleData(Map<PathKey, List<ScheduledLeg>> legs,
                             Map<LocalDate, Set<String>> activeServices,
                             Map<String, String> stopNames) {
            this.legs = legs;
            this.activeServices = activeServices;
            this.stopNames = stopNames;
            legs.values().forEach(pathLegs -> pathLegs.forEach(leg -> tripIds.add(leg.tripId())));
        }

        private Map<String, String> stopNames() { return stopNames; }

        private Set<String> tripIds() { return tripIds; }

        private Map<PathKey, List<LegInstance>> instances(LocalDate today) {
            Map<PathKey, List<LegInstance>> result = new EnumMap<>(PathKey.class);
            for (PathKey key : PathKey.values()) result.put(key, new ArrayList<>());
            for (int offset = -1; offset <= 8; offset++) {
                LocalDate serviceDate = today.plusDays(offset);
                Set<String> services = activeServices.getOrDefault(serviceDate, Set.of());
                if (services.isEmpty()) continue;
                for (List<ScheduledLeg> pathLegs : legs.values()) {
                    for (ScheduledLeg leg : pathLegs) {
                        if (!services.contains(leg.serviceId())) continue;
                        try {
                            Instant departure = serviceInstant(serviceDate, leg.departure());
                            Instant arrival = serviceInstant(serviceDate, leg.arrival());
                            if (!arrival.isBefore(departure)) {
                                result.get(leg.path()).add(new LegInstance(
                                        leg.path(), leg.tripId(), serviceDate, departure, departure, arrival, null));
                            }
                        } catch (IllegalArgumentException ignored) {
                        }
                    }
                }
            }
            result.values().forEach(list -> list.sort(Comparator.comparing(LegInstance::departure)));
            return result;
        }
    }

    private static Instant serviceInstant(LocalDate date, String gtfsTime) {
        String[] parts = gtfsTime.split(":");
        if (parts.length != 3) throw new IllegalArgumentException("Invalid GTFS time.");
        long seconds = Long.parseLong(parts[0]) * 3600 + Long.parseLong(parts[1]) * 60 + Long.parseLong(parts[2]);
        return date.atTime(LocalTime.NOON).atZone(ZONE).toInstant()
                .minus(Duration.ofHours(12)).plusSeconds(seconds);
    }

    private static final class ScheduleRepository {
        private final Path dataDirectory;
        private final Path archive;
        private final Path indexFile;
        private final Path metadataFile;
        private final URI feedUri;
        private final boolean localArchive;
        private final HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(20))
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build();
        private final Properties metadata = new Properties();
        private volatile FeedState current;
        private Instant lastSuccess;
        private Instant lastAttempt;

        private ScheduleRepository(Path dataDirectory, Path archive, URI feedUri, boolean localArchive) {
            this.dataDirectory = dataDirectory.toAbsolutePath();
            this.archive = archive.toAbsolutePath();
            this.indexFile = this.dataDirectory.resolve("openov-schedule-index.csv");
            this.metadataFile = this.dataDirectory.resolve("openov-feed.properties");
            this.feedUri = feedUri;
            this.localArchive = localArchive;
        }

        private FeedState state() { return current; }

        private synchronized void loadCache() {
            try {
                Files.createDirectories(dataDirectory);
                if (Files.isRegularFile(metadataFile)) {
                    try (InputStream input = Files.newInputStream(metadataFile)) { metadata.load(input); }
                }
                lastSuccess = parseInstant(metadata.getProperty("lastSuccess"));
                lastAttempt = parseInstant(metadata.getProperty("lastAttempt"));
                if (!Files.isRegularFile(archive)) return;

                String cacheKey = archiveKey();
                ScheduleData data = readIndex(cacheKey);
                if (data == null) {
                    data = parseFeed(archive);
                    writeIndex(data, cacheKey);
                }
                Instant fetchedAt = lastSuccess;
                if (fetchedAt == null) fetchedAt = Files.getLastModifiedTime(archive).toInstant();
                boolean stale = !localArchive && (lastSuccess == null
                        || Instant.now().isAfter(lastSuccess.plus(FEED_CHECK_INTERVAL)));
                if (localArchive) stale = false;
                current = new FeedState(data, fetchedAt, stale);
            } catch (IOException | RuntimeException exception) {
                System.err.println("Could not load cached OpenOV schedule: " + exception.getMessage());
            }
        }

        private synchronized void refreshIfDue() {
            if (localArchive) return;
            Instant now = Instant.now();
            if (lastAttempt != null && now.isBefore(lastAttempt.plus(RETRY_INTERVAL))) return;
            if (lastSuccess != null && now.isBefore(lastSuccess.plus(FEED_CHECK_INTERVAL))) return;
            lastAttempt = now;
            saveMetadataQuietly();
            Path temporaryArchive = archive.resolveSibling(archive.getFileName() + ".part");
            try {
                Files.createDirectories(archive.getParent());
                HttpRequest.Builder request = HttpRequest.newBuilder(feedUri)
                        .timeout(Duration.ofMinutes(20))
                        .header("User-Agent", "NextLeg/1.0 (self-hosted Java static GTFS client)")
                        .header("Accept", "application/zip")
                        .header("Accept-Encoding", "gzip")
                        .GET();
                String etag = metadata.getProperty("etag");
                String modified = metadata.getProperty("lastModified");
                if (etag != null && !etag.isBlank()) request.header("If-None-Match", etag);
                if (modified != null && !modified.isBlank()) request.header("If-Modified-Since", modified);
                HttpResponse<InputStream> response = client.send(request.build(), HttpResponse.BodyHandlers.ofInputStream());
                try (InputStream body = response.body()) {
                    if (response.statusCode() == 304) {
                        if (current == null && Files.isRegularFile(archive)) {
                            current = new FeedState(parseFeed(archive), Files.getLastModifiedTime(archive).toInstant(), true);
                        }
                        if (current == null) throw new IOException("OpenOV returned 304 without a usable cached schedule.");
                        response.headers().firstValue("ETag").ifPresent(value -> metadata.setProperty("etag", value));
                        response.headers().firstValue("Last-Modified").ifPresent(value -> metadata.setProperty("lastModified", value));
                        lastSuccess = now;
                        metadata.setProperty("lastSuccess", now.toString());
                        current = new FeedState(current.data(), now, false);
                        saveMetadataQuietly();
                        return;
                    }
                    if (response.statusCode() != 200) {
                        throw new IOException("OpenOV returned HTTP " + response.statusCode() + ".");
                    }
                    try (InputStream decoded = isGzip(response) ? new GZIPInputStream(body) : body) {
                        Files.copy(decoded, temporaryArchive, StandardCopyOption.REPLACE_EXISTING);
                    }
                }

                ScheduleData updated = parseFeed(temporaryArchive);
                moveAtomically(temporaryArchive, archive);
                response.headers().firstValue("ETag").ifPresent(value -> metadata.setProperty("etag", value));
                response.headers().firstValue("Last-Modified").ifPresent(value -> metadata.setProperty("lastModified", value));
                lastSuccess = now;
                metadata.setProperty("lastSuccess", now.toString());
                current = new FeedState(updated, now, false);
                try { writeIndex(updated, archiveKey()); } catch (IOException exception) {
                    System.err.println("OpenOV schedule index could not be saved: " + exception.getMessage());
                }
                saveMetadataQuietly();
                System.out.println("Loaded OpenOV static schedule.");
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
                markRefreshFailed("request interrupted");
            } catch (IOException | RuntimeException exception) {
                markRefreshFailed(exception.getMessage());
            } finally {
                try { Files.deleteIfExists(temporaryArchive); } catch (IOException ignored) {}
            }
        }

        private void markRefreshFailed(String reason) {
            FeedState previous = current;
            if (previous != null) current = new FeedState(previous.data(), previous.fetchedAt(), true);
            System.err.println("OpenOV schedule refresh failed" + (reason == null ? "." : ": " + reason));
            saveMetadataQuietly();
        }

        private void saveMetadataQuietly() {
            metadata.setProperty("lastAttempt", lastAttempt.toString());
            try { saveMetadata(); } catch (IOException exception) {
                System.err.println("Could not save OpenOV feed metadata: " + exception.getMessage());
            }
        }

        private void saveMetadata() throws IOException {
            Files.createDirectories(dataDirectory);
            Path temp = metadataFile.resolveSibling(metadataFile.getFileName() + ".part");
            try (var output = Files.newOutputStream(temp)) { metadata.store(output, "OpenOV static schedule cache"); }
            moveAtomically(temp, metadataFile);
        }

        private String archiveKey() throws IOException {
            String etag = metadata.getProperty("etag", "");
            return etag + "|" + Files.size(archive) + "|" + Files.getLastModifiedTime(archive).toMillis();
        }

        private ScheduleData readIndex(String key) throws IOException {
            if (!Files.isRegularFile(indexFile)) return null;
            try (BufferedReader reader = Files.newBufferedReader(indexFile, StandardCharsets.UTF_8)) {
                if (!"NEXTLEG-INDEX-1".equals(reader.readLine()) || !key.equals(reader.readLine())) return null;
                EnumMap<PathKey, List<ScheduledLeg>> legs = emptyLegLists();
                Map<LocalDate, Set<String>> services = new TreeMap<>();
                Map<String, String> stops = new HashMap<>();
                String line;
                while ((line = reader.readLine()) != null) {
                    List<String> fields = csv(line);
                    if (fields.isEmpty()) continue;
                    switch (fields.get(0)) {
                        case "D" -> services.computeIfAbsent(LocalDate.parse(fields.get(1), GTFS_DATE), ignored -> new HashSet<>()).add(fields.get(2));
                        case "S" -> stops.put(fields.get(1), fields.get(2));
                        case "L" -> legs.get(PathKey.valueOf(fields.get(1))).add(
                                new ScheduledLeg(PathKey.valueOf(fields.get(1)), fields.get(2), fields.get(3), fields.get(4), fields.get(5)));
                        default -> throw new IOException("Invalid schedule index record.");
                    }
                }
                validateSchedule(legs, stops);
                return new ScheduleData(legs, services, stops);
            } catch (RuntimeException exception) {
                return null;
            }
        }

        private void writeIndex(ScheduleData data, String key) throws IOException {
            Files.createDirectories(dataDirectory);
            Path temp = indexFile.resolveSibling(indexFile.getFileName() + ".part");
            try (var writer = Files.newBufferedWriter(temp, StandardCharsets.UTF_8)) {
                writer.write("NEXTLEG-INDEX-1\n");
                writer.write(key);
                writer.newLine();
                for (var day : new TreeMap<>(data.activeServices).entrySet()) {
                    for (String service : day.getValue()) writeCsv(writer, List.of("D", GTFS_DATE.format(day.getKey()), service));
                }
                for (var stop : new TreeMap<>(data.stopNames).entrySet()) writeCsv(writer, List.of("S", stop.getKey(), stop.getValue()));
                for (PathKey path : PathKey.values()) {
                    for (ScheduledLeg leg : data.legs.getOrDefault(path, List.of())) {
                        writeCsv(writer, List.of("L", path.name(), leg.serviceId(), leg.tripId(), leg.departure(), leg.arrival()));
                    }
                }
            }
            moveAtomically(temp, indexFile);
        }

        private static EnumMap<PathKey, List<ScheduledLeg>> emptyLegLists() {
            EnumMap<PathKey, List<ScheduledLeg>> result = new EnumMap<>(PathKey.class);
            for (PathKey key : PathKey.values()) result.put(key, new ArrayList<>());
            return result;
        }

        private static ScheduleData parseFeed(Path path) throws IOException {
            try (ZipFile zip = new ZipFile(path.toFile())) {
                Map<String, String> routePatterns = readRoutes(zip);
                Map<String, TripMeta> trips = readTrips(zip, routePatterns);
                Map<String, List<StopTime>> stopsByTrip = readStopTimes(zip, trips);
                Map<LocalDate, Set<String>> services = readCalendarDates(zip);
                Map<String, String> stopNames = readTargetStops(zip);
                EnumMap<PathKey, List<ScheduledLeg>> legs = emptyLegLists();
                Map<String, List<PathSpec>> specsByRoute = new HashMap<>();
                for (PathSpec spec : PATHS) specsByRoute.computeIfAbsent(spec.routePattern(), ignored -> new ArrayList<>()).add(spec);
                for (var entry : stopsByTrip.entrySet()) {
                    TripMeta trip = trips.get(entry.getKey());
                    if (trip == null) continue;
                    List<StopTime> points = entry.getValue();
                    points.sort(Comparator.comparingInt(StopTime::sequence));
                    for (PathSpec spec : specsByRoute.getOrDefault(trip.routePattern(), List.of())) {
                        StopTime from = null;
                        StopTime to = null;
                        for (StopTime candidateFrom : points) {
                            if (!candidateFrom.stopId().equals(spec.fromStop()) || candidateFrom.departure().isBlank()) continue;
                            for (StopTime candidateTo : points) {
                                if (candidateTo.stopId().equals(spec.toStop()) && candidateTo.sequence() > candidateFrom.sequence()
                                        && !candidateTo.arrival().isBlank()) {
                                    from = candidateFrom;
                                    to = candidateTo;
                                    break;
                                }
                            }
                            if (from != null) break;
                        }
                        if (from != null) legs.get(spec.key()).add(new ScheduledLeg(
                                spec.key(), trip.serviceId(), entry.getKey(), from.departure(), to.arrival()));
                    }
                }
                for (List<ScheduledLeg> pathLegs : legs.values()) {
                    pathLegs.sort(Comparator.comparing(ScheduledLeg::serviceId).thenComparing(ScheduledLeg::departure));
                }
                validateSchedule(legs, stopNames);
                return new ScheduleData(legs, services, stopNames);
            }
        }

        private static Map<String, String> readRoutes(ZipFile zip) throws IOException {
            Map<String, String> result = new HashMap<>();
            try (BufferedReader reader = reader(zip, "routes.txt")) {
                Map<String, Integer> header = header(reader.readLine());
                String line;
                while ((line = reader.readLine()) != null) {
                    List<String> fields = csv(line);
                    String routeId = value(fields, header, "route_id");
                    String agency = value(fields, header, "agency_id");
                    String shortName = value(fields, header, "route_short_name");
                    String longName = value(fields, header, "route_long_name");
                    if (agency.equals("BRAVO:ARR") && (shortName.equals("305") || shortName.equals("306"))) {
                        result.put(routeId, shortName);
                    } else if (agency.equals("IFF:NS") && (shortName.equals("IC3500") || longName.contains("IC3500"))) {
                        result.put(routeId, "IC3500");
                    }
                }
            }
            if (!result.containsValue("305") || !result.containsValue("306") || !result.containsValue("IC3500")) {
                throw new IOException("OpenOV feed is missing a required BRAVO or NS route.");
            }
            return result;
        }

        private static Map<String, TripMeta> readTrips(ZipFile zip, Map<String, String> routePatterns) throws IOException {
            Map<String, TripMeta> result = new HashMap<>();
            try (BufferedReader reader = reader(zip, "trips.txt")) {
                Map<String, Integer> header = header(reader.readLine());
                String line;
                int routeColumn = header.get("route_id");
                int serviceColumn = header.get("service_id");
                int tripColumn = header.get("trip_id");
                while ((line = reader.readLine()) != null) {
                    String routeId;
                    String serviceId;
                    String tripId;
                    if (routeColumn == 0 && serviceColumn == 1 && tripColumn == 2) {
                        int first = line.indexOf(',');
                        if (first < 0) continue;
                        routeId = line.substring(0, first);
                        String pattern = routePatterns.get(routeId);
                        if (pattern == null) continue;
                        int second = line.indexOf(',', first + 1);
                        if (second < 0) continue;
                        serviceId = line.substring(first + 1, second);
                        int third = line.indexOf(',', second + 1);
                        tripId = line.substring(second + 1, third < 0 ? line.length() : third);
                        result.put(tripId, new TripMeta(pattern, serviceId));
                    } else {
                        List<String> fields = csv(line);
                        routeId = value(fields, header, "route_id");
                        serviceId = value(fields, header, "service_id");
                        tripId = value(fields, header, "trip_id");
                        String pattern = routePatterns.get(routeId);
                        if (pattern != null) result.put(tripId, new TripMeta(pattern, serviceId));
                    }
                }
            }
            return result;
        }

        private static Map<String, List<StopTime>> readStopTimes(ZipFile zip, Map<String, TripMeta> trips) throws IOException {
            Set<String> targetIds = new HashSet<>();
            for (PathSpec spec : PATHS) { targetIds.add(spec.fromStop()); targetIds.add(spec.toStop()); }
            Map<String, List<StopTime>> result = new HashMap<>();
            try (BufferedReader reader = reader(zip, "stop_times.txt")) {
                Map<String, Integer> header = header(reader.readLine());
                int tripColumn = header.get("trip_id");
                String currentTripId = null;
                TripMeta currentTrip = null;
                while (true) {
                    String line = reader.readLine();
                    if (line == null) break;
                    int firstComma = line.indexOf(',');
                    if (firstComma < 0) continue;
                    String tripId;
                    if (tripColumn == 0) {
                        int length = firstComma;
                        if (currentTripId != null && currentTripId.length() == length
                                && line.regionMatches(0, currentTripId, 0, length)) {
                            tripId = currentTripId;
                        } else {
                            tripId = line.substring(0, length);
                            currentTripId = tripId;
                            currentTrip = trips.get(tripId);
                        }
                    } else {
                        tripId = csv(line).get(tripColumn);
                        currentTrip = trips.get(tripId);
                    }
                    if (currentTrip == null) continue;
                    List<String> fields = csv(line);
                    String stopId = value(fields, header, "stop_id");
                    if (!targetIds.contains(stopId)) continue;
                    int sequence = Integer.parseInt(value(fields, header, "stop_sequence"));
                    String arrival = value(fields, header, "arrival_time");
                    String departure = value(fields, header, "departure_time");
                    result.computeIfAbsent(tripId, ignored -> new ArrayList<>())
                            .add(new StopTime(stopId, sequence, arrival, departure));
                }
            }
            return result;
        }

        private static Map<LocalDate, Set<String>> readCalendarDates(ZipFile zip) throws IOException {
            Map<LocalDate, Set<String>> result = new TreeMap<>();
            boolean hasCalendar = zip.getEntry("calendar.txt") != null;
            ZipEntry exceptions = zip.getEntry("calendar_dates.txt");
            if (!hasCalendar && exceptions == null) {
                throw new IOException("OpenOV feed has neither calendar.txt nor calendar_dates.txt.");
            }
            if (hasCalendar) {
                try (BufferedReader reader = reader(zip, "calendar.txt")) {
                    Map<String, Integer> header = header(reader.readLine());
                    String line;
                    while ((line = reader.readLine()) != null) {
                        List<String> fields = csv(line);
                        String service = value(fields, header, "service_id");
                        LocalDate start = LocalDate.parse(value(fields, header, "start_date"), GTFS_DATE);
                        LocalDate end = LocalDate.parse(value(fields, header, "end_date"), GTFS_DATE);
                        for (LocalDate date = start; !date.isAfter(end); date = date.plusDays(1)) {
                            String day = date.getDayOfWeek().name().toLowerCase(Locale.ROOT);
                            if (value(fields, header, day).equals("1")) {
                                result.computeIfAbsent(date, ignored -> new HashSet<>()).add(service);
                            }
                        }
                    }
                }
            }
            if (exceptions == null) return result;
            try (BufferedReader reader = reader(zip, "calendar_dates.txt")) {
                Map<String, Integer> header = header(reader.readLine());
                String line;
                while ((line = reader.readLine()) != null) {
                    List<String> fields = csv(line);
                    LocalDate date = LocalDate.parse(value(fields, header, "date"), GTFS_DATE);
                    String service = value(fields, header, "service_id");
                    int exception = Integer.parseInt(value(fields, header, "exception_type"));
                    Set<String> active = result.computeIfAbsent(date, ignored -> new HashSet<>());
                    if (exception == 1) active.add(service);
                    else if (exception == 2) active.remove(service);
                    else throw new IOException("Invalid calendar exception type " + exception + ".");
                }
            }
            return result;
        }

        private static Map<String, String> readTargetStops(ZipFile zip) throws IOException {
            Set<String> targetIds = new HashSet<>();
            for (PathSpec spec : PATHS) { targetIds.add(spec.fromStop()); targetIds.add(spec.toStop()); }
            Map<String, String> result = new HashMap<>();
            try (BufferedReader reader = reader(zip, "stops.txt")) {
                Map<String, Integer> header = header(reader.readLine());
                String line;
                while ((line = reader.readLine()) != null) {
                    List<String> fields = csv(line);
                    String id = value(fields, header, "stop_id");
                    if (targetIds.contains(id)) result.put(id, value(fields, header, "stop_name"));
                }
            }
            if (!result.keySet().containsAll(targetIds)) throw new IOException("OpenOV feed is missing one or more configured stops.");
            return result;
        }

        private static void validateSchedule(Map<PathKey, List<ScheduledLeg>> legs, Map<String, String> stops) throws IOException {
            for (PathSpec spec : PATHS) {
                if (legs.getOrDefault(spec.key(), List.of()).isEmpty()) {
                    throw new IOException("OpenOV feed is missing the stop sequence for " + spec.key() + ".");
                }
                if (!stops.containsKey(spec.fromStop()) || !stops.containsKey(spec.toStop())) {
                    throw new IOException("OpenOV feed is missing a configured stop name.");
                }
            }
        }

        private static BufferedReader reader(ZipFile zip, String entryName) throws IOException {
            ZipEntry entry = zip.getEntry(entryName);
            if (entry == null) throw new IOException("OpenOV feed has no " + entryName + ".");
            return new BufferedReader(new InputStreamReader(zip.getInputStream(entry), StandardCharsets.UTF_8), 1 << 20);
        }

        private static Map<String, Integer> header(String line) throws IOException {
            if (line == null) throw new IOException("GTFS CSV file is empty.");
            List<String> fields = csv(line.startsWith("\uFEFF") ? line.substring(1) : line);
            Map<String, Integer> result = new HashMap<>();
            for (int index = 0; index < fields.size(); index++) result.put(fields.get(index), index);
            return result;
        }

        private static String value(List<String> fields, Map<String, Integer> header, String name) throws IOException {
            Integer index = header.get(name);
            if (index == null || index >= fields.size()) throw new IOException("GTFS CSV is missing column " + name + ".");
            return fields.get(index);
        }
    }

    /** OpenOV realtime trip updates for trains and buses. Fetched when a journey is requested, at most once a minute. */
    private static final class RealtimeFeeds {
        private static final List<URI> FEEDS = List.of(
                URI.create("https://gtfs.openov.nl/gtfs-rt/trainUpdates.pb"),
                URI.create("https://gtfs.openov.nl/gtfs-rt/tripUpdates.pb"));
        private static final Duration CHECK_INTERVAL = Duration.ofMinutes(1);
        private static final Duration MAX_AGE = Duration.ofMinutes(10);
        private final HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(4))
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build();
        private final Map<URI, String> etags = new HashMap<>();
        private final Map<URI, Map<String, TripUpdate>> updates = new HashMap<>();
        private final Map<URI, Instant> loadedAt = new HashMap<>();
        private Instant checkedAt = Instant.EPOCH;

        /** Updates keyed by trip id and service date, such as "381881923|20260930". Old data is dropped after ten minutes. */
        private synchronized Map<String, TripUpdate> current(Set<String> tripIds, Instant now) {
            if (now.isAfter(checkedAt.plus(CHECK_INTERVAL))) {
                checkedAt = now;
                for (URI feed : FEEDS) refresh(feed, tripIds, now);
            }
            Map<String, TripUpdate> result = new HashMap<>();
            for (URI feed : FEEDS) {
                Instant loaded = loadedAt.get(feed);
                if (loaded != null && now.isBefore(loaded.plus(MAX_AGE))) result.putAll(updates.get(feed));
            }
            return result;
        }

        private void refresh(URI feed, Set<String> tripIds, Instant now) {
            try {
                HttpRequest.Builder request = HttpRequest.newBuilder(feed)
                        .timeout(Duration.ofSeconds(4))
                        .header("User-Agent", "NextLeg/1.0 (self-hosted Java GTFS-RT client)")
                        .header("Accept-Encoding", "gzip")
                        .GET();
                String etag = etags.get(feed);
                if (etag != null) request.header("If-None-Match", etag);
                HttpResponse<byte[]> response = client.send(request.build(), HttpResponse.BodyHandlers.ofByteArray());
                if (response.statusCode() == 304) {
                    loadedAt.put(feed, now);
                    return;
                }
                if (response.statusCode() != 200) throw new IOException("HTTP " + response.statusCode() + ".");
                byte[] body = response.body();
                if (isGzip(response)) {
                    try (InputStream decoded = new GZIPInputStream(new ByteArrayInputStream(body))) { body = decoded.readAllBytes(); }
                }
                updates.put(feed, parseTripUpdates(body, tripIds));
                response.headers().firstValue("ETag").ifPresent(value -> etags.put(feed, value));
                loadedAt.put(feed, now);
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
            } catch (IOException | RuntimeException exception) {
                System.err.println("OpenOV realtime " + feed.getPath() + " failed: " + exception.getMessage());
            }
        }

        /** Reads a GTFS-RT FeedMessage and keeps only the trips NextLeg uses. */
        private static Map<String, TripUpdate> parseTripUpdates(byte[] bytes, Set<String> tripIds) {
            Map<String, TripUpdate> result = new HashMap<>();
            Instant updatedAt = null;
            Protobuf feed = new Protobuf(bytes, 0, bytes.length);
            while (feed.next()) {
                if (feed.is(1, 2)) {
                    Protobuf header = feed.message();
                    while (header.next()) {
                        if (header.is(3, 0)) updatedAt = Instant.ofEpochSecond(header.varint());
                        else header.skip();
                    }
                } else if (feed.is(2, 2)) {
                    Protobuf entity = feed.message();
                    while (entity.next()) {
                        if (entity.is(3, 2)) readTripUpdate(entity.message(), tripIds, updatedAt, result);
                        else entity.skip();
                    }
                } else {
                    feed.skip();
                }
            }
            return result;
        }

        private static void readTripUpdate(Protobuf update, Set<String> tripIds, Instant updatedAt,
                                           Map<String, TripUpdate> result) {
            String tripId = null;
            String startDate = null;
            boolean cancelled = false;
            List<Protobuf> stops = new ArrayList<>();
            while (update.next()) {
                if (update.is(1, 2)) {
                    Protobuf trip = update.message();
                    while (trip.next()) {
                        if (trip.is(1, 2)) tripId = trip.string();
                        else if (trip.is(3, 2)) startDate = trip.string();
                        else if (trip.is(4, 0)) cancelled = trip.varint() == 3;
                        else trip.skip();
                    }
                } else if (update.is(2, 2)) {
                    stops.add(update.message());
                } else {
                    update.skip();
                }
            }
            if (tripId == null || startDate == null || !tripIds.contains(tripId)) return;

            // A stop without its own times inherits the delay of the stop before it, as GTFS-RT defines.
            Map<String, StopUpdate> stopUpdates = new HashMap<>();
            Integer carriedDelay = null;
            for (Protobuf stop : stops) {
                String stopId = null;
                Integer arrival = null;
                Integer departure = null;
                boolean skipped = false;
                String platform = null;
                while (stop.next()) {
                    if (stop.is(2, 2)) arrival = delay(stop.message());
                    else if (stop.is(3, 2)) departure = delay(stop.message());
                    else if (stop.is(4, 2)) stopId = stop.string();
                    else if (stop.is(5, 0)) skipped = stop.varint() == 1;
                    else if (stop.is(1003, 2)) platform = platform(stop.message());
                    else stop.skip();
                }
                if (arrival == null) arrival = carriedDelay;
                if (departure == null) departure = arrival;
                if (departure != null) carriedDelay = departure;
                if (stopId != null) stopUpdates.put(stopId, new StopUpdate(arrival, departure, skipped, platform));
            }
            result.put(tripId + "|" + startDate, new TripUpdate(cancelled, stopUpdates, updatedAt));
        }

        private static Integer delay(Protobuf event) {
            Integer delay = null;
            while (event.next()) {
                if (event.is(1, 0)) delay = (int) event.varint();
                else event.skip();
            }
            return delay;
        }

        /** OVapi extension on a stop: field 2 is the actual track, field 1 the planned one. */
        private static String platform(Protobuf extension) {
            String planned = null;
            String actual = null;
            while (extension.next()) {
                if (extension.is(1, 2)) planned = extension.string();
                else if (extension.is(2, 2)) actual = extension.string();
                else extension.skip();
            }
            return actual != null && !actual.isBlank() ? actual : planned;
        }
    }

    /** Just enough protobuf decoding for GTFS-RT. Fields NextLeg does not use are skipped. */
    private static final class Protobuf {
        private final byte[] bytes;
        private final int end;
        private int position;
        private int field;
        private int wireType;

        private Protobuf(byte[] bytes, int start, int end) {
            this.bytes = bytes;
            this.position = start;
            this.end = end;
        }

        private boolean next() {
            if (position >= end) return false;
            long key = varint();
            field = (int) (key >>> 3);
            wireType = (int) (key & 7);
            return true;
        }

        private boolean is(int field, int wireType) {
            return this.field == field && this.wireType == wireType;
        }

        private long varint() {
            long result = 0;
            for (int shift = 0; shift < 64; shift += 7) {
                byte next = bytes[position++];
                result |= (long) (next & 0x7f) << shift;
                if (next >= 0) return result;
            }
            throw new IllegalArgumentException("Invalid protobuf varint.");
        }

        private Protobuf message() {
            int length = (int) varint();
            Protobuf message = new Protobuf(bytes, position, position + length);
            position += length;
            return message;
        }

        private String string() {
            int length = (int) varint();
            String value = new String(bytes, position, length, StandardCharsets.UTF_8);
            position += length;
            return value;
        }

        private void skip() {
            switch (wireType) {
                case 0 -> varint();
                case 1 -> position += 8;
                case 2 -> {
                    int length = (int) varint();
                    position += length;
                }
                case 5 -> position += 4;
                default -> throw new IllegalArgumentException("Unsupported protobuf wire type " + wireType + ".");
            }
        }
    }

    private static boolean isGzip(HttpResponse<?> response) {
        return response.headers().firstValue("Content-Encoding").orElse("").toLowerCase().contains("gzip");
    }

    private static Instant parseInstant(String value) {
        if (value == null || value.isBlank()) return null;
        try { return Instant.parse(value); } catch (RuntimeException ignored) { return null; }
    }

    private static void moveAtomically(Path source, Path destination) throws IOException {
        try {
            Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (AtomicMoveNotSupportedException exception) {
            Files.move(source, destination, StandardCopyOption.REPLACE_EXISTING);
        }
    }

    private static List<String> csv(String line) {
        List<String> fields = new ArrayList<>();
        StringBuilder field = new StringBuilder();
        boolean quoted = false;
        for (int index = 0; index < line.length(); index++) {
            char character = line.charAt(index);
            if (quoted) {
                if (character == '"' && index + 1 < line.length() && line.charAt(index + 1) == '"') {
                    field.append('"');
                    index++;
                } else if (character == '"') {
                    quoted = false;
                } else {
                    field.append(character);
                }
            } else if (character == ',' ) {
                fields.add(field.toString());
                field.setLength(0);
            } else if (character == '"' && field.isEmpty()) {
                quoted = true;
            } else {
                field.append(character);
            }
        }
        fields.add(field.toString());
        return fields;
    }

    private static void writeCsv(java.io.Writer writer, List<String> fields) throws IOException {
        for (int index = 0; index < fields.size(); index++) {
            if (index > 0) writer.write(',');
            String value = fields.get(index);
            if (value.indexOf(',') >= 0 || value.indexOf('"') >= 0 || value.indexOf('\n') >= 0) {
                writer.write('"');
                writer.write(value.replace("\"", "\"\""));
                writer.write('"');
            } else {
                writer.write(value);
            }
        }
        writer.write('\n');
    }
}
