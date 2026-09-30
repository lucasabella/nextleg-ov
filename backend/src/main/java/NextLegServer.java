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
import java.text.Normalizer;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
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
    // A phone notices it left the home or work area a few minutes after its first vehicle departs.
    private static final Duration BOARDED_BEFORE = Duration.ofMinutes(30);
    private static final Duration BOARDED_AFTER = Duration.ofMinutes(5);
    private static final Duration BOARDED_NOTICE_DELAY = Duration.ofMinutes(2);
    // Delays can make a ride scheduled before the transfer window catchable, so candidates are checked this far back.
    private static final Duration DELAY_SLACK = Duration.ofHours(3);
    private static final URI DEFAULT_FEED_URI = URI.create("https://gtfs.openov.nl/gtfs-rt/gtfs-openov-nl.zip");
    private static final DateTimeFormatter GTFS_DATE = DateTimeFormatter.BASIC_ISO_DATE;
    private static final DateTimeFormatter ISO_INSTANT = DateTimeFormatter.ISO_INSTANT;
    // Used when a request only names a direction: Blerick station and the Corridor bus stop in Veghel.
    private static final String DEFAULT_HOME = "Blerick|51.373|6.155";
    private static final String DEFAULT_WORK = "Veghel, Corridor|51.600|5.519";
    /** Service days kept in memory: yesterday, for trips running past midnight, up to the day after tomorrow. */
    private static final int WINDOW_DAYS = 4;
    /** Stops this close count as one place to change at, such as a station and the bus station next to it. */
    private static final double TRANSFER_WALK_METERS = 400;
    private static final int MAX_WATCHED_PLACES = 8;
    private static final String[] MODES = {"train", "bus", "tram", "metro", "ferry"};

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
        RealtimeFeeds realtime = new RealtimeFeeds();
        Set<String> watched = new LinkedHashSet<>(List.of(DEFAULT_HOME, DEFAULT_WORK));

        HttpServer server = HttpServer.create(new InetSocketAddress(host, port), 0);
        server.createContext("/", exchange -> handle(exchange, schedules, realtime, watched, transferBufferMinutes, maxTransferWaitMinutes));
        server.start();

        ScheduledExecutorService refresh = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "openov-schedule-refresh");
            thread.setDaemon(true);
            return thread;
        });
        // Reading the whole timetable takes a minute or two on a Raspberry Pi, so it happens after the server is up.
        refresh.execute(schedules::loadCache);
        refresh.scheduleWithFixedDelay(schedules::refreshIfDue, 0, 15, TimeUnit.MINUTES);
        System.out.println("NextLeg service listening on " + host + ":" + port
                + "; transfer buffer is a configurable heuristic, not GTFS walking time (" + transferBufferMinutes
                + " to " + maxTransferWaitMinutes + " minutes).");
    }

    private static void handle(HttpExchange exchange, ScheduleRepository schedules, RealtimeFeeds realtime, Set<String> watched,
                               int transferBufferMinutes, int maxTransferWaitMinutes) throws IOException {
        String path = exchange.getRequestURI().getPath();
        if (!path.equals("/health") && !path.equals("/api/v1/journey") && !path.equals("/api/v1/stops")) {
            send(exchange, 404, "{\"error\":\"Not found.\"}");
            return;
        }
        if (!exchange.getRequestMethod().equals("GET")) {
            send(exchange, 405, "{\"error\":\"Method not allowed. Use GET.\"}");
            return;
        }
        if (path.equals("/health")) {
            send(exchange, 200, "{\"status\":\"ok\"}");
            return;
        }
        FeedState state = schedules.state();
        if (state == null) {
            send(exchange, 503, "{\"error\":\"The OpenOV timetable is still loading or unavailable. Try again in a minute.\"}");
            return;
        }
        String body;
        try {
            String query = exchange.getRequestURI().getRawQuery();
            body = path.equals("/api/v1/stops")
                    ? stopsJson(state.data(), queryParameter(query, "query"))
                    : journeyResponse(query, state, realtime, watched, transferBufferMinutes, maxTransferWaitMinutes);
        } catch (IllegalArgumentException exception) {
            send(exchange, 400, jsonError(exception.getMessage()));
            return;
        }
        send(exchange, 200, body);
    }

    private static String journeyResponse(String query, FeedState state, RealtimeFeeds realtime, Set<String> watched,
                                          int bufferMinutes, int maxWaitMinutes) {
        String direction = queryParameter(query, "direction");
        if (direction == null || direction.isBlank()) {
            throw new IllegalArgumentException("Missing required query parameter: direction.");
        }
        if (!direction.equals("to_veghel") && !direction.equals("to_blerick")) {
            throw new IllegalArgumentException("Invalid direction. Use to_veghel or to_blerick.");
        }
        LocalTime usualDeparture = requestedDeparture(queryParameter(query, "departure"));
        Instant boardedAt = requestedBoardedAt(queryParameter(query, "boardedAt"));
        Timetable timetable = state.data();
        boolean toWork = direction.equals("to_veghel");
        int origin = place(timetable, queryParameter(query, "from"), toWork ? DEFAULT_HOME : DEFAULT_WORK);
        int destination = place(timetable, queryParameter(query, "to"), toWork ? DEFAULT_WORK : DEFAULT_HOME);
        if (origin == destination) throw new IllegalArgumentException("Choose two different stops.");

        // Realtime data covers the trips at places recent requests used, so newly chosen stops get it too.
        for (int place : new int[] {origin, destination}) {
            watched.remove(timetable.placeIds[place]);
            watched.add(timetable.placeIds[place]);
        }
        while (watched.size() > MAX_WATCHED_PLACES) watched.remove(watched.iterator().next());
        Instant now = Instant.now();
        Map<String, TripUpdate> updates = realtime.current(timetable.tripIdsAt(watched), now);

        Search search = new Search(timetable, updates, origin, destination, bufferMinutes, maxWaitMinutes);
        Journey journey = boardedAt == null ? null : search.boarded(boardedAt);
        if (journey == null) journey = usualDeparture == null ? search.next(now) : search.usual(usualDeparture, now);
        return journeyJson(direction, journey, state, now);
    }

    private static int place(Timetable timetable, String id, String fallback) {
        String wanted = id == null || id.isBlank() ? fallback : id;
        Integer place = timetable.find(wanted);
        if (place == null) throw new IllegalArgumentException("Unknown stop " + wanted + ". Search for it again.");
        return place;
    }

    /**
     * Finds the journey that arrives first, direct or with one change, using expected times where realtime data
     * knows them. Between two journeys that arrive together, the one that leaves later wins.
     */
    private static final class Search {
        private final Timetable timetable;
        private final Map<String, TripUpdate> updates;
        private final int origin;
        private final int destination;
        private final Duration buffer;
        private final Duration maxWait;
        /** Per stop, the rides from there to the destination, as pairs of boarding and alighting stop times. */
        private final Map<Integer, List<int[]>> towardsDestination = new HashMap<>();

        private Search(Timetable timetable, Map<String, TripUpdate> updates, int origin, int destination,
                       int bufferMinutes, int maxWaitMinutes) {
            this.timetable = timetable;
            this.updates = updates;
            this.origin = origin;
            this.destination = destination;
            this.buffer = Duration.ofMinutes(bufferMinutes);
            this.maxWait = Duration.ofMinutes(maxWaitMinutes);
            for (int stop : timetable.placeStops[destination]) {
                for (int index = timetable.stopEventStarts[stop]; index < timetable.stopEventStarts[stop + 1]; index++) {
                    int alight = timetable.stopEvents[index];
                    if (!timetable.canAlight(alight)) continue;
                    for (int board = timetable.tripStarts[timetable.eventTrips[alight]]; board < alight; board++) {
                        if (!timetable.canBoard(board) || timetable.placeOf(board) == destination) continue;
                        towardsDestination.computeIfAbsent(timetable.eventStops[board], ignored -> new ArrayList<>())
                                .add(new int[] {board, alight});
                    }
                }
            }
        }

        private Journey next(Instant now) {
            return best(boardings(now, now.plus(Duration.ofDays(1))));
        }

        /** The first journey leaving at or after the usual time. Once today's has left, it looks at the next days. */
        private Journey usual(LocalTime usualDeparture, Instant now) {
            LocalDate today = now.atZone(ZONE).toLocalDate();
            for (int day = 0; day < WINDOW_DAYS - 1; day++) {
                Instant usual = today.plusDays(day).atTime(usualDeparture).atZone(ZONE).toInstant();
                Journey journey = best(boardings(usual, usual.plus(Duration.ofHours(12))));
                if (journey != null && journey.departure().isAfter(now)) return journey;
            }
            return null;
        }

        /**
         * The journey the phone is on: the first ride that left closest to when the phone is likely to have left,
         * counted from 30 minutes before to 5 minutes after it left its start area. Null when none fits.
         */
        private Journey boarded(Instant boardedAt) {
            Instant likelyDeparture = boardedAt.minus(BOARDED_NOTICE_DELAY);
            List<Boarding> candidates = boardings(boardedAt.minus(BOARDED_BEFORE), boardedAt.plus(BOARDED_AFTER));
            candidates.sort(Comparator.comparing(boarding -> Duration.between(likelyDeparture, boarding.departure()).abs()));
            for (Boarding boarding : candidates) {
                Journey journey = best(List.of(boarding));
                if (journey != null) return journey;
            }
            return null;
        }

        /** Every dated departure from the origin between two times, earliest first. */
        private List<Boarding> boardings(Instant from, Instant until) {
            List<Boarding> result = new ArrayList<>();
            for (int stop : timetable.placeStops[origin]) {
                for (int index = timetable.stopEventStarts[stop]; index < timetable.stopEventStarts[stop + 1]; index++) {
                    int event = timetable.stopEvents[index];
                    if (!timetable.canBoard(event)) continue;
                    int trip = timetable.eventTrips[event];
                    for (int day = 0; day < WINDOW_DAYS; day++) {
                        if ((timetable.tripDays[trip] & 1 << day) == 0) continue;
                        Instant scheduled = timetable.instant(day, timetable.departures[event]);
                        if (scheduled.isBefore(from.minus(DELAY_SLACK)) || scheduled.isAfter(until)) continue;
                        Ride ride = ride(trip, day, event, event);
                        if (ride != null && !ride.departure().isBefore(from) && !ride.departure().isAfter(until)) {
                            result.add(new Boarding(trip, day, event, ride.departure()));
                        }
                    }
                }
            }
            result.sort(Comparator.comparing(Boarding::departure));
            return result;
        }

        private Journey best(List<Boarding> boardings) {
            Journey best = null;
            for (Boarding boarding : boardings) {
                // A later departure cannot arrive before the best journey found so far.
                if (best != null && boarding.departure().isAfter(best.arrival())) break;
                int trip = boarding.trip();
                for (int alight = boarding.event() + 1; alight < timetable.tripStarts[trip + 1]; alight++) {
                    if (!timetable.canAlight(alight) || timetable.placeOf(alight) == origin) continue;
                    Ride first = ride(trip, boarding.day(), boarding.event(), alight);
                    if (first == null) continue;
                    if (timetable.placeOf(alight) == destination) {
                        best = better(best, new Journey(List.of(first)));
                        continue;
                    }
                    Instant earliest = first.arrival().plus(buffer);
                    Instant latest = first.arrival().plus(maxWait);
                    int stop = timetable.eventStops[alight];
                    for (int near = timetable.nearbyStarts[stop]; near < timetable.nearbyStarts[stop + 1]; near++) {
                        for (int[] onward : towardsDestination.getOrDefault(timetable.nearbyStops[near], List.of())) {
                            int nextTrip = timetable.eventTrips[onward[0]];
                            if (nextTrip == trip) continue;
                            for (int day = 0; day < WINDOW_DAYS; day++) {
                                if ((timetable.tripDays[nextTrip] & 1 << day) == 0) continue;
                                Instant scheduled = timetable.instant(day, timetable.departures[onward[0]]);
                                if (scheduled.isBefore(earliest.minus(DELAY_SLACK)) || scheduled.isAfter(latest)) continue;
                                Ride second = ride(nextTrip, day, onward[0], onward[1]);
                                if (second == null || second.departure().isBefore(earliest) || second.departure().isAfter(latest)) continue;
                                best = better(best, new Journey(List.of(first, second)));
                            }
                        }
                    }
                }
            }
            return best;
        }

        private static Journey better(Journey best, Journey candidate) {
            if (best == null) return candidate;
            int arrival = candidate.arrival().compareTo(best.arrival());
            if (arrival != 0) return arrival < 0 ? candidate : best;
            int departure = candidate.departure().compareTo(best.departure());
            if (departure != 0) return departure > 0 ? candidate : best;
            return candidate.rides().size() < best.rides().size() ? candidate : best;
        }

        /**
         * One dated ride, moved to its expected times when the realtime feed has them. Null when the trip is
         * cancelled or skips one of the two stops. Rides without realtime keep their scheduled times.
         */
        private Ride ride(int trip, int day, int board, int alight) {
            Instant scheduledDeparture = timetable.instant(day, timetable.departures[board]);
            Instant scheduledArrival = timetable.instant(day, timetable.arrivals[alight]);
            TripUpdate update = updates.get(timetable.tripIds[trip] + "|" + timetable.dayKeys[day]);
            StopUpdate from = update == null ? null : update.stops().get(timetable.stopIds[timetable.eventStops[board]]);
            StopUpdate to = update == null ? null : update.stops().get(timetable.stopIds[timetable.eventStops[alight]]);
            if (update != null && (update.cancelled() || from != null && from.skipped() || to != null && to.skipped())) return null;
            if ((from == null || from.departureDelay() == null && from.platform() == null)
                    && (to == null || to.arrivalDelay() == null)) {
                return new Ride(trip, day, board, alight, scheduledDeparture, scheduledArrival, scheduledDeparture, scheduledArrival, null);
            }
            Integer delay = from == null ? null : from.departureDelay();
            int arrivalDelay = to == null || to.arrivalDelay() == null ? (delay == null ? 0 : delay) : to.arrivalDelay();
            return new Ride(trip, day, board, alight, scheduledDeparture, scheduledArrival,
                    scheduledDeparture.plusSeconds(delay == null ? 0 : delay), scheduledArrival.plusSeconds(arrivalDelay),
                    new Live(delay, from == null ? null : from.platform(), update.updatedAt()));
        }
    }

    private static String journeyJson(String direction, Journey journey, FeedState state, Instant now) {
        StringBuilder json = new StringBuilder("{\"direction\":\"" + direction + "\",\"fetchedAt\":\"" + ISO_INSTANT.format(now)
                + "\",\"freshness\":\"" + (state.stale() ? "stale" : "fresh") + "\",\"legs\":[");
        if (journey != null) {
            for (int index = 0; index < journey.rides().size(); index++) {
                if (index > 0) json.append(',');
                json.append(legJson(state.data(), journey.rides().get(index)));
            }
        }
        return json.append("]}").toString();
    }

    private static String legJson(Timetable timetable, Ride ride) {
        int boardStop = timetable.eventStops[ride.board()];
        StringBuilder json = new StringBuilder("{\"mode\":\"" + MODES[timetable.tripModes[ride.trip()]]
                + "\",\"origin\":\"" + jsonEscape(timetable.stopNames[boardStop])
                + "\",\"destination\":\"" + jsonEscape(timetable.stopNames[timetable.eventStops[ride.alight()]])
                + "\",\"scheduledDeparture\":\"" + ISO_INSTANT.format(ride.scheduledDeparture())
                + "\",\"scheduledArrival\":\"" + ISO_INSTANT.format(ride.scheduledArrival()) + "\"");
        Live live = ride.live();
        if (live == null) {
            json.append(",\"status\":\"scheduled\"");
        } else {
            if (Math.abs(Duration.between(ride.scheduledArrival(), ride.arrival()).toSeconds()) >= 60) {
                json.append(",\"expectedArrival\":\"").append(ISO_INSTANT.format(ride.arrival())).append('"');
            }
            // Differences under a minute count as on time, like departure boards do.
            if (live.delaySeconds() != null && Math.abs(live.delaySeconds()) >= 60) {
                json.append(",\"expectedDeparture\":\"").append(ISO_INSTANT.format(ride.departure()))
                        .append("\",\"delaySeconds\":").append(live.delaySeconds());
            }
            json.append(",\"status\":\"").append(live.delaySeconds() == null ? "scheduled"
                    : live.delaySeconds() >= 60 ? "delayed" : "on_time").append('"');
        }
        // A live track change wins over the planned platform from the timetable.
        String platform = live != null && live.platform() != null ? live.platform() : timetable.stopPlatforms[boardStop];
        if (!platform.isEmpty()) json.append(",\"platform\":\"").append(jsonEscape(platform)).append('"');
        if (live != null && live.updatedAt() != null) {
            json.append(",\"sourceUpdatedAt\":\"").append(ISO_INSTANT.format(live.updatedAt())).append('"');
        }
        return json.append('}').toString();
    }

    private static String stopsJson(Timetable timetable, String query) {
        if (query == null || normalize(query).length() < 2) {
            throw new IllegalArgumentException("Type at least two letters to search for a stop.");
        }
        StringBuilder json = new StringBuilder("{\"stops\":[");
        List<Integer> places = timetable.search(query, 15);
        for (int index = 0; index < places.size(); index++) {
            int place = places.get(index);
            if (index > 0) json.append(',');
            json.append("{\"id\":\"").append(jsonEscape(timetable.placeIds[place]))
                    .append("\",\"name\":\"").append(jsonEscape(timetable.placeNames[place]))
                    .append("\",\"latitude\":").append(Math.round(timetable.placeLatitudes[place] * 1e6) / 1e6)
                    .append(",\"longitude\":").append(Math.round(timetable.placeLongitudes[place] * 1e6) / 1e6)
                    .append(",\"modes\":[");
            boolean first = true;
            for (int mode = 0; mode < MODES.length; mode++) {
                if ((timetable.placeModes[place] & 1 << mode) == 0) continue;
                if (!first) json.append(',');
                json.append('"').append(MODES[mode]).append('"');
                first = false;
            }
            json.append("]}");
        }
        return json.append("]}").toString();
    }

    /** Lower case without accents or punctuation, so "koln" finds "Köln" and "veghel corridor" finds "Veghel, Corridor". */
    private static String normalize(String text) {
        return Normalizer.normalize(text, Normalizer.Form.NFD).replaceAll("\\p{M}", "")
                .toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9]+", " ").trim();
    }

    private static LocalTime requestedDeparture(String departure) {
        if (departure == null) return null;
        try {
            return LocalTime.parse(departure);
        } catch (DateTimeParseException exception) {
            throw new IllegalArgumentException("Invalid departure. Use HH:mm, such as 07:10.");
        }
    }

    private static Instant requestedBoardedAt(String boardedAt) {
        if (boardedAt == null) return null;
        try {
            return Instant.parse(boardedAt);
        } catch (DateTimeParseException exception) {
            throw new IllegalArgumentException("Invalid boardedAt. Use an ISO 8601 time, such as 2026-09-30T05:10:00Z.");
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

    /** One dated ride from a boarding to an alighting stop time. Departure and arrival are expected times when known. */
    private record Ride(int trip, int day, int board, int alight, Instant scheduledDeparture, Instant scheduledArrival,
                        Instant departure, Instant arrival, Live live) {}
    private record Journey(List<Ride> rides) {
        private Instant departure() { return rides.get(0).departure(); }
        private Instant arrival() { return rides.get(rides.size() - 1).arrival(); }
    }
    private record Boarding(int trip, int day, int event, Instant departure) {}
    private record Live(Integer delaySeconds, String platform, Instant updatedAt) {}
    private record StopUpdate(Integer arrivalDelay, Integer departureDelay, boolean skipped, String platform) {}
    private record TripUpdate(boolean cancelled, Map<String, StopUpdate> stops, Instant updatedAt) {}
    private record FeedState(Timetable data, Instant fetchedAt, boolean stale) {}

    /**
     * The whole OpenOV timetable for a few service days, kept compact: every stop time is a slot in a few arrays, and a
     * trip is a range of slots. A place is what you search for, such as all platforms of one station.
     */
    private static final class Timetable {
        private static final int CAN_BOARD = 1;
        private static final int CAN_ALIGHT = 2;
        private static final double CELL_DEGREES = 0.005;

        private final LocalDate firstDay;
        private final String[] dayKeys = new String[WINDOW_DAYS];
        private final long[] dayStarts = new long[WINDOW_DAYS];
        private final String[] stopIds;
        private final String[] stopNames;
        private final String[] stopPlatforms;
        private final double[] stopLatitudes;
        private final double[] stopLongitudes;
        private final int[] stopPlaces;
        /** The stop times at stop s are stopEvents[stopEventStarts[s]] up to stopEvents[stopEventStarts[s + 1]]. */
        private final int[] stopEventStarts;
        private final int[] stopEvents;
        /** Stops within walking distance of stop s, itself included, stored the same way. */
        private final int[] nearbyStarts;
        private final int[] nearbyStops;
        private final String[] tripIds;
        private final int[] tripModes;
        /** Bit d is set when the trip runs on service day firstDay + d. */
        private final int[] tripDays;
        /** The stop times of trip t are the slots from tripStarts[t] up to tripStarts[t + 1]. */
        private final int[] tripStarts;
        private final int[] eventTrips;
        private final int[] eventStops;
        /** Seconds after the start of the service day. Trips running past midnight go beyond 24:00. */
        private final int[] arrivals;
        private final int[] departures;
        private final byte[] eventFlags;
        private final String[] placeIds;
        private final String[] placeNames;
        private final String[] placeSearchNames;
        private final double[] placeLatitudes;
        private final double[] placeLongitudes;
        private final int[][] placeStops;
        private final int[] placeModes;
        private final int[] placeDepartures;
        private final Map<String, List<Integer>> placesByName;

        private static Timetable read(Path archive, LocalDate today) throws IOException {
            try (ZipFile zip = new ZipFile(archive.toFile())) {
                return new Timetable(zip, today.minusDays(1));
            }
        }

        private Timetable(ZipFile zip, LocalDate firstDay) throws IOException {
            this.firstDay = firstDay;
            Map<LocalDate, Set<String>> calendar = readCalendarDates(zip);
            Map<String, Integer> serviceDays = new HashMap<>();
            for (int day = 0; day < WINDOW_DAYS; day++) {
                LocalDate date = firstDay.plusDays(day);
                dayKeys[day] = GTFS_DATE.format(date);
                // GTFS times count from noon minus 12 hours, which differs from midnight on daylight saving days.
                dayStarts[day] = date.atTime(LocalTime.NOON).atZone(ZONE).toEpochSecond() - 12 * 3600;
                int bit = 1 << day;
                for (String service : calendar.getOrDefault(date, Set.of())) serviceDays.merge(service, bit, (a, b) -> a | b);
            }

            List<String[]> stops = new ArrayList<>();
            Map<String, String[]> stations = new HashMap<>();
            try (BufferedReader reader = reader(zip, "stops.txt")) {
                Map<String, Integer> header = header(reader.readLine());
                Integer platformColumn = header.get("platform_code");
                Integer parentColumn = header.get("parent_station");
                Integer typeColumn = header.get("location_type");
                String line;
                while ((line = reader.readLine()) != null) {
                    List<String> fields = csv(line);
                    String type = typeColumn == null || typeColumn >= fields.size() ? "" : fields.get(typeColumn);
                    String[] stop = {value(fields, header, "stop_id"), value(fields, header, "stop_name"),
                            value(fields, header, "stop_lat"), value(fields, header, "stop_lon"),
                            platformColumn == null || platformColumn >= fields.size() ? "" : fields.get(platformColumn),
                            parentColumn == null || parentColumn >= fields.size() ? "" : fields.get(parentColumn)};
                    if (type.equals("1")) stations.put(stop[0], stop);
                    else if (type.isEmpty() || type.equals("0")) stops.add(stop);
                }
            }
            int stopCount = stops.size();
            stopIds = new String[stopCount];
            stopNames = new String[stopCount];
            stopPlatforms = new String[stopCount];
            stopLatitudes = new double[stopCount];
            stopLongitudes = new double[stopCount];
            Map<String, Integer> stopIndex = new HashMap<>();
            for (int stop = 0; stop < stopCount; stop++) {
                String[] row = stops.get(stop);
                stopIds[stop] = row[0];
                stopNames[stop] = row[1];
                stopLatitudes[stop] = Double.parseDouble(row[2]);
                stopLongitudes[stop] = Double.parseDouble(row[3]);
                stopPlatforms[stop] = row[4];
                stopIndex.put(row[0], stop);
            }

            StopTimes stopTimes = readStopTimes(zip, readTrips(zip, serviceDays, readRouteModes(zip)), stopIndex);
            if (stopTimes.tripIds.isEmpty()) throw new IOException("OpenOV feed has no trips in the coming days.");
            tripIds = stopTimes.tripIds.toArray(String[]::new);
            tripModes = stopTimes.tripModes.take();
            tripDays = stopTimes.tripDays.take();
            stopTimes.tripStarts.add(stopTimes.stops.size());
            tripStarts = stopTimes.tripStarts.take();
            eventStops = stopTimes.stops.take();
            arrivals = stopTimes.arrivals.take();
            departures = stopTimes.departures.take();
            eventFlags = new byte[eventStops.length];
            for (int event = 0; event < eventFlags.length; event++) eventFlags[event] = (byte) stopTimes.flags.get(event);
            stopTimes.flags.take();
            eventTrips = new int[eventStops.length];
            for (int trip = 0; trip < tripIds.length; trip++) Arrays.fill(eventTrips, tripStarts[trip], tripStarts[trip + 1], trip);

            stopEventStarts = new int[stopCount + 1];
            for (int stop : eventStops) stopEventStarts[stop + 1]++;
            for (int stop = 0; stop < stopCount; stop++) stopEventStarts[stop + 1] += stopEventStarts[stop];
            stopEvents = new int[eventStops.length];
            int[] filled = Arrays.copyOf(stopEventStarts, stopCount);
            for (int event = 0; event < eventStops.length; event++) stopEvents[filled[eventStops[event]]++] = event;

            // Stops share a place when they have the same name within a kilometre: the platforms of a station, both
            // sides of a road, or two station areas with one name.
            stopPlaces = new int[stopCount];
            List<String> ids = new ArrayList<>();
            List<String> names = new ArrayList<>();
            List<double[]> positions = new ArrayList<>();
            List<Ints> members = new ArrayList<>();
            placesByName = new HashMap<>();
            for (int stop = 0; stop < stopCount; stop++) {
                String[] station = stations.get(stops.get(stop)[5]);
                boolean isStation = station != null && !station[2].isEmpty() && !station[3].isEmpty();
                String name = isStation ? station[1] : stopNames[stop];
                double latitude = isStation ? Double.parseDouble(station[2]) : stopLatitudes[stop];
                double longitude = isStation ? Double.parseDouble(station[3]) : stopLongitudes[stop];
                Integer place = null;
                for (int candidate : placesByName.getOrDefault(name, List.of())) {
                    double[] position = positions.get(candidate);
                    if (meters(position[0], position[1], latitude, longitude) <= 1_000) {
                        place = candidate;
                        break;
                    }
                }
                if (place == null) {
                    place = ids.size();
                    placesByName.computeIfAbsent(name, ignored -> new ArrayList<>()).add(place);
                    // OpenOV renumbers stops between feeds, so a place id is its name and rounded position.
                    ids.add(String.format(Locale.ROOT, "%s|%.3f|%.3f", name, latitude, longitude));
                    names.add(name);
                    positions.add(new double[] {latitude, longitude});
                    members.add(new Ints());
                }
                members.get(place).add(stop);
                stopPlaces[stop] = place;
            }
            int placeCount = ids.size();
            placeIds = ids.toArray(String[]::new);
            placeNames = names.toArray(String[]::new);
            placeSearchNames = new String[placeCount];
            placeLatitudes = new double[placeCount];
            placeLongitudes = new double[placeCount];
            placeStops = new int[placeCount][];
            for (int place = 0; place < placeCount; place++) {
                placeSearchNames[place] = normalize(placeNames[place]);
                // Most people call 's-Hertogenbosch Den Bosch.
                if (placeSearchNames[place].contains("s hertogenbosch")) placeSearchNames[place] += " den bosch";
                placeLatitudes[place] = positions.get(place)[0];
                placeLongitudes[place] = positions.get(place)[1];
                placeStops[place] = members.get(place).toArray();
            }
            placeModes = new int[placeCount];
            placeDepartures = new int[placeCount];
            for (int event = 0; event < eventStops.length; event++) {
                if (!canBoard(event)) continue;
                int place = stopPlaces[eventStops[event]];
                placeModes[place] |= 1 << tripModes[eventTrips[event]];
                placeDepartures[place]++;
            }

            Map<Long, Ints> grid = new HashMap<>();
            for (int stop = 0; stop < stopCount; stop++) {
                grid.computeIfAbsent(cell(stopLatitudes[stop], stopLongitudes[stop], 0, 0), ignored -> new Ints()).add(stop);
            }
            Ints nearby = new Ints();
            nearbyStarts = new int[stopCount + 1];
            for (int stop = 0; stop < stopCount; stop++) {
                nearbyStarts[stop] = nearby.size();
                for (int row = -1; row <= 1; row++) {
                    for (int column = -1; column <= 1; column++) {
                        Ints candidates = grid.get(cell(stopLatitudes[stop], stopLongitudes[stop], row, column));
                        if (candidates == null) continue;
                        for (int index = 0; index < candidates.size(); index++) {
                            int other = candidates.get(index);
                            if (meters(stopLatitudes[stop], stopLongitudes[stop], stopLatitudes[other], stopLongitudes[other])
                                    <= TRANSFER_WALK_METERS) nearby.add(other);
                        }
                    }
                }
            }
            nearbyStarts[stopCount] = nearby.size();
            nearbyStops = nearby.toArray();
        }

        private Instant instant(int day, int seconds) { return Instant.ofEpochSecond(dayStarts[day] + seconds); }

        private boolean canBoard(int event) { return (eventFlags[event] & CAN_BOARD) != 0; }

        private boolean canAlight(int event) { return (eventFlags[event] & CAN_ALIGHT) != 0; }

        private int placeOf(int event) { return stopPlaces[eventStops[event]]; }

        private String summary() {
            return tripIds.length + " trips, " + eventStops.length + " stop times, " + placeIds.length + " places from "
                    + firstDay + " for " + WINDOW_DAYS + " days";
        }

        /**
         * The place an id such as "Veghel, Corridor|51.600|5.519" names: the nearest place with that name within two
         * kilometres, so an id saved on a phone keeps working after OpenOV renumbers its stops.
         */
        private Integer find(String id) {
            int longitude = id.lastIndexOf('|');
            int latitude = longitude < 1 ? -1 : id.lastIndexOf('|', longitude - 1);
            if (latitude < 1) return null;
            double wantedLatitude;
            double wantedLongitude;
            try {
                wantedLatitude = Double.parseDouble(id.substring(latitude + 1, longitude));
                wantedLongitude = Double.parseDouble(id.substring(longitude + 1));
            } catch (NumberFormatException exception) {
                return null;
            }
            Integer best = null;
            double bestMeters = 2_000;
            for (int place : placesByName.getOrDefault(id.substring(0, latitude), List.of())) {
                double distance = meters(placeLatitudes[place], placeLongitudes[place], wantedLatitude, wantedLongitude);
                if (distance <= bestMeters) {
                    best = place;
                    bestMeters = distance;
                }
            }
            return best;
        }

        /** The trips that stop at the given places, for realtime updates. */
        private Set<String> tripIdsAt(Collection<String> places) {
            Set<String> result = new HashSet<>();
            for (String id : places) {
                Integer place = find(id);
                if (place == null) continue;
                for (int stop : placeStops[place]) {
                    for (int index = stopEventStarts[stop]; index < stopEventStarts[stop + 1]; index++) {
                        result.add(tripIds[eventTrips[stopEvents[index]]]);
                    }
                }
            }
            return result;
        }

        /**
         * Places with departures whose name has every typed word at the start of one of its words. Names starting
         * with the whole query come first, then train stations, then places with more departures.
         */
        private List<Integer> search(String query, int limit) {
            String typed = normalize(query);
            String[] words = typed.split(" ");
            List<Integer> result = new ArrayList<>();
            for (int place = 0; place < placeSearchNames.length; place++) {
                if (placeDepartures[place] == 0) continue;
                String name = " " + placeSearchNames[place];
                boolean matches = true;
                for (String word : words) {
                    if (!name.contains(" " + word)) {
                        matches = false;
                        break;
                    }
                }
                if (matches) result.add(place);
            }
            result.sort(Comparator.<Integer>comparingInt(place -> placeSearchNames[place].startsWith(typed) ? 0 : 1)
                    .thenComparingInt(place -> (placeModes[place] & 1) != 0 ? 0 : 1)
                    .thenComparingInt(place -> -placeDepartures[place]));
            return result.subList(0, Math.min(limit, result.size()));
        }

        private static long cell(double latitude, double longitude, int rowOffset, int columnOffset) {
            long row = (long) Math.floor(latitude / CELL_DEGREES) + rowOffset;
            long column = (long) Math.floor(longitude / CELL_DEGREES) + columnOffset;
            return row << 32 ^ (column & 0xffffffffL);
        }

        private static double meters(double latitude, double longitude, double otherLatitude, double otherLongitude) {
            double x = Math.toRadians(otherLongitude - longitude) * Math.cos(Math.toRadians((latitude + otherLatitude) / 2));
            double y = Math.toRadians(otherLatitude - latitude);
            return Math.sqrt(x * x + y * y) * 6_371_000;
        }

        /** Seconds after the start of the service day for a GTFS time such as 25:10:00, or -1 when empty or invalid. */
        private static int seconds(String time) {
            int first = time.indexOf(':');
            int second = time.indexOf(':', first + 1);
            if (first < 0 || second < 0) return -1;
            try {
                return Integer.parseInt(time.substring(0, first).trim()) * 3600
                        + Integer.parseInt(time.substring(first + 1, second)) * 60
                        + Integer.parseInt(time.substring(second + 1).trim());
            } catch (NumberFormatException exception) {
                return -1;
            }
        }

        /** Reads the stop times of the given trips, trip by trip. Trips with fewer than two known stops are left out. */
        private static StopTimes readStopTimes(ZipFile zip, Map<String, int[]> trips, Map<String, Integer> stopIndex)
                throws IOException {
            StopTimes stopTimes = new StopTimes();
            try (BufferedReader reader = reader(zip, "stop_times.txt")) {
                Map<String, Integer> header = header(reader.readLine());
                int tripColumn = column(header, "trip_id");
                int sequenceColumn = column(header, "stop_sequence");
                int stopColumn = column(header, "stop_id");
                int arrivalColumn = column(header, "arrival_time");
                int departureColumn = column(header, "departure_time");
                Integer pickupColumn = header.get("pickup_type");
                Integer dropOffColumn = header.get("drop_off_type");
                String currentId = null;
                int[] current = null;
                String line;
                while ((line = reader.readLine()) != null) {
                    String tripId;
                    int comma = line.indexOf(',');
                    if (tripColumn != 0) {
                        tripId = csv(line).get(tripColumn);
                    } else if (comma < 0) {
                        continue;
                    } else if (currentId != null && comma == currentId.length() && line.startsWith(currentId)) {
                        tripId = currentId;
                    } else {
                        tripId = line.substring(0, comma);
                    }
                    if (!tripId.equals(currentId)) {
                        if (current != null) stopTimes.endTrip(currentId, current);
                        currentId = tripId;
                        current = trips.get(tripId);
                    }
                    if (current == null) continue;
                    List<String> fields = csv(line);
                    Integer stop = stopIndex.get(fields.get(stopColumn));
                    int arrival = seconds(fields.get(arrivalColumn));
                    int departure = seconds(fields.get(departureColumn));
                    if (arrival < 0) arrival = departure;
                    if (departure < 0) departure = arrival;
                    if (stop == null || arrival < 0) continue;
                    boolean noPickup = pickupColumn != null && pickupColumn < fields.size() && fields.get(pickupColumn).equals("1");
                    boolean noDropOff = dropOffColumn != null && dropOffColumn < fields.size() && fields.get(dropOffColumn).equals("1");
                    stopTimes.add(Integer.parseInt(fields.get(sequenceColumn)), stop, arrival, departure,
                            (noPickup ? 0 : CAN_BOARD) | (noDropOff ? 0 : CAN_ALIGHT));
                }
                if (current != null) stopTimes.endTrip(currentId, current);
            }
            return stopTimes;
        }

        private static Map<String, Integer> readRouteModes(ZipFile zip) throws IOException {
            Map<String, Integer> result = new HashMap<>();
            try (BufferedReader reader = reader(zip, "routes.txt")) {
                Map<String, Integer> header = header(reader.readLine());
                String line;
                while ((line = reader.readLine()) != null) {
                    List<String> fields = csv(line);
                    result.put(value(fields, header, "route_id"), mode(Integer.parseInt(value(fields, header, "route_type"))));
                }
            }
            return result;
        }

        /** GTFS route types, basic and extended, as an index into MODES. */
        private static int mode(int routeType) {
            if (routeType == 2 || routeType >= 100 && routeType < 200) return 0;
            if (routeType == 0 || routeType >= 900 && routeType < 1000) return 2;
            if (routeType == 1 || routeType >= 400 && routeType < 500) return 3;
            if (routeType == 4 || routeType >= 1000 && routeType < 1300) return 4;
            return 1;
        }

        /** Trips that run on a day in the window, by trip id, as their mode and day bits. */
        private static Map<String, int[]> readTrips(ZipFile zip, Map<String, Integer> serviceDays, Map<String, Integer> routeModes)
                throws IOException {
            Map<String, int[]> result = new HashMap<>();
            try (BufferedReader reader = reader(zip, "trips.txt")) {
                Map<String, Integer> header = header(reader.readLine());
                int routeColumn = column(header, "route_id");
                int serviceColumn = column(header, "service_id");
                int tripColumn = column(header, "trip_id");
                String line;
                while ((line = reader.readLine()) != null) {
                    List<String> fields = csv(line);
                    Integer days = serviceDays.get(fields.get(serviceColumn));
                    Integer mode = routeModes.get(fields.get(routeColumn));
                    if (days != null && mode != null) result.put(fields.get(tripColumn), new int[] {mode, days});
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

        private static int column(Map<String, Integer> header, String name) throws IOException {
            Integer index = header.get(name);
            if (index == null) throw new IOException("GTFS CSV is missing column " + name + ".");
            return index;
        }
    }

    /** Collects stop times trip by trip while stop_times.txt streams past. */
    private static final class StopTimes {
        private final List<String> tripIds = new ArrayList<>();
        private final Ints tripModes = new Ints();
        private final Ints tripDays = new Ints();
        private final Ints tripStarts = new Ints();
        /** Stop sequences of the trip being read, only needed to put its stops in order. */
        private final Ints sequences = new Ints();
        private final Ints stops = new Ints();
        private final Ints arrivals = new Ints();
        private final Ints departures = new Ints();
        private final Ints flags = new Ints();
        private int start;

        private void add(int sequence, int stop, int arrival, int departure, int flag) {
            sequences.add(sequence);
            stops.add(stop);
            arrivals.add(arrival);
            departures.add(departure);
            flags.add(flag);
        }

        /** Keeps the stop times read since the previous trip, in stop order, when there are at least two. */
        private void endTrip(String tripId, int[] trip) {
            int end = stops.size();
            List<Ints> columns = List.of(stops, arrivals, departures, flags);
            if (end - start < 2) {
                columns.forEach(column -> column.truncate(start));
                sequences.truncate(0);
                return;
            }
            boolean sorted = true;
            for (int index = 1; index < sequences.size(); index++) sorted &= sequences.get(index) >= sequences.get(index - 1);
            if (!sorted) {
                Integer[] order = new Integer[end - start];
                for (int index = 0; index < order.length; index++) order[index] = index;
                Arrays.sort(order, Comparator.comparingInt(sequences::get));
                for (Ints column : columns) {
                    int[] values = new int[order.length];
                    for (int index = 0; index < order.length; index++) values[index] = column.get(start + order[index]);
                    for (int index = 0; index < order.length; index++) column.set(start + index, values[index]);
                }
            }
            sequences.truncate(0);
            tripIds.add(tripId);
            tripModes.add(trip[0]);
            tripDays.add(trip[1]);
            tripStarts.add(start);
            start = end;
        }
    }

    /** A growable int array, so millions of stop times do not each become an object. */
    private static final class Ints {
        private int[] values = new int[16];
        private int size;

        private void add(int value) {
            if (size == values.length) values = Arrays.copyOf(values, size * 2);
            values[size++] = value;
        }

        private int get(int index) { return values[index]; }

        private void set(int index, int value) { values[index] = value; }

        private int size() { return size; }

        private void truncate(int newSize) { size = newSize; }

        private int[] toArray() { return Arrays.copyOf(values, size); }

        /** The values as an exact array. The list is empty afterwards, so its memory can be reclaimed. */
        private int[] take() {
            int[] result = toArray();
            values = new int[16];
            size = 0;
            return result;
        }
    }

    private static final class ScheduleRepository {
        private final Path dataDirectory;
        private final Path archive;
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
            this.metadataFile = this.dataDirectory.resolve("openov-feed.properties");
            this.feedUri = feedUri;
            this.localArchive = localArchive;
        }

        private FeedState state() { return current; }

        private synchronized void loadCache() {
            try {
                Files.createDirectories(dataDirectory);
                // Older versions kept an index of a few fixed routes here. The whole timetable is read now.
                Files.deleteIfExists(dataDirectory.resolve("openov-schedule-index.csv"));
                if (Files.isRegularFile(metadataFile)) {
                    try (InputStream input = Files.newInputStream(metadataFile)) { metadata.load(input); }
                }
                lastSuccess = parseInstant(metadata.getProperty("lastSuccess"));
                lastAttempt = parseInstant(metadata.getProperty("lastAttempt"));
                if (!Files.isRegularFile(archive)) return;

                Timetable data = Timetable.read(archive, today());
                Instant fetchedAt = lastSuccess;
                if (fetchedAt == null) fetchedAt = Files.getLastModifiedTime(archive).toInstant();
                boolean stale = !localArchive && (lastSuccess == null
                        || Instant.now().isAfter(lastSuccess.plus(FEED_CHECK_INTERVAL)));
                current = new FeedState(data, fetchedAt, stale);
                System.out.println("Loaded OpenOV timetable: " + data.summary() + ".");
            } catch (IOException | RuntimeException exception) {
                System.err.println("Could not load cached OpenOV schedule: " + exception.getMessage());
            }
        }

        private synchronized void refreshIfDue() {
            moveWindowIfDue();
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
                            current = new FeedState(Timetable.read(archive, today()), Files.getLastModifiedTime(archive).toInstant(), true);
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

                Timetable updated = Timetable.read(temporaryArchive, today());
                moveAtomically(temporaryArchive, archive);
                response.headers().firstValue("ETag").ifPresent(value -> metadata.setProperty("etag", value));
                response.headers().firstValue("Last-Modified").ifPresent(value -> metadata.setProperty("lastModified", value));
                lastSuccess = now;
                metadata.setProperty("lastSuccess", now.toString());
                current = new FeedState(updated, now, false);
                saveMetadataQuietly();
                System.out.println("Loaded OpenOV timetable: " + updated.summary() + ".");
            } catch (InterruptedException exception) {
                Thread.currentThread().interrupt();
                markRefreshFailed("request interrupted");
            } catch (IOException | RuntimeException exception) {
                markRefreshFailed(exception.getMessage());
            } finally {
                try { Files.deleteIfExists(temporaryArchive); } catch (IOException ignored) {}
            }
        }

        /** The timetable starts the day before today. After midnight it is read again from the saved feed. */
        private void moveWindowIfDue() {
            FeedState state = current;
            if (state == null || state.data().firstDay.equals(today().minusDays(1)) || !Files.isRegularFile(archive)) return;
            try {
                Timetable moved = Timetable.read(archive, today());
                current = new FeedState(moved, state.fetchedAt(), state.stale());
                System.out.println("Loaded OpenOV timetable: " + moved.summary() + ".");
            } catch (IOException | RuntimeException exception) {
                System.err.println("Could not move the timetable to today: " + exception.getMessage());
            }
        }

        private static LocalDate today() { return LocalDate.now(ZONE); }

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
    }

    /** OpenOV realtime trip updates for trains and buses. Fetched when a journey is requested, at most once a minute. */
    private static final class RealtimeFeeds {
        private static final List<URI> FEEDS = List.of(
                URI.create("https://gtfs.openov.nl/gtfs-rt/trainUpdates.pb"),
                URI.create("https://gtfs.openov.nl/gtfs-rt/tripUpdates.pb"));
        private static final Duration CHECK_INTERVAL = Duration.ofMinutes(1);
        private static final Duration MAX_AGE = Duration.ofMinutes(10);
        private static final Duration NEW_TRIPS_INTERVAL = Duration.ofSeconds(15);
        private final HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(4))
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build();
        private final Map<URI, String> etags = new HashMap<>();
        private final Map<URI, Map<String, TripUpdate>> updates = new HashMap<>();
        private final Map<URI, Instant> loadedAt = new HashMap<>();
        private Instant checkedAt = Instant.EPOCH;
        private Set<String> checkedTrips = Set.of();

        /**
         * Updates keyed by trip id and service date, such as "381881923|20260930". Old data is dropped after ten
         * minutes. When a request asks about trips the last check skipped, the feeds are read again sooner.
         */
        private synchronized Map<String, TripUpdate> current(Set<String> tripIds, Instant now) {
            boolean newTrips = !checkedTrips.containsAll(tripIds);
            if (now.isAfter(checkedAt.plus(CHECK_INTERVAL)) || newTrips && now.isAfter(checkedAt.plus(NEW_TRIPS_INTERVAL))) {
                checkedAt = now;
                checkedTrips = tripIds;
                // A 304 would keep updates filtered for the old trips, so new trips need the whole feed.
                for (URI feed : FEEDS) refresh(feed, tripIds, now, !newTrips);
            }
            Map<String, TripUpdate> result = new HashMap<>();
            for (URI feed : FEEDS) {
                Instant loaded = loadedAt.get(feed);
                if (loaded != null && now.isBefore(loaded.plus(MAX_AGE))) result.putAll(updates.get(feed));
            }
            return result;
        }

        private void refresh(URI feed, Set<String> tripIds, Instant now, boolean conditional) {
            try {
                HttpRequest.Builder request = HttpRequest.newBuilder(feed)
                        .timeout(Duration.ofSeconds(4))
                        .header("User-Agent", "NextLeg/1.0 (self-hosted Java GTFS-RT client)")
                        .header("Accept-Encoding", "gzip")
                        .GET();
                String etag = etags.get(feed);
                if (etag != null && conditional) request.header("If-None-Match", etag);
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
}
