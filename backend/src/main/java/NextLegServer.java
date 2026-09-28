import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;

public final class NextLegServer {
    private static final String TO_VEGHEL = """
            {"direction":"to_veghel","fetchedAt":"2026-09-28T06:10:00Z","freshness":"sample","legs":[{"mode":"train","origin":"Sample origin","destination":"Sample transfer","scheduledDeparture":"2026-09-28T06:14:00Z","expectedDeparture":"2026-09-28T06:19:00Z","status":"delayed","delaySeconds":300,"platform":"3","sourceUpdatedAt":"2026-09-28T06:09:00Z"},{"mode":"bus","origin":"Sample transfer","destination":"Sample destination","scheduledDeparture":"2026-09-28T06:42:00Z","status":"scheduled"}]}
            """;
    private static final String TO_BLERICK = """
            {"direction":"to_blerick","fetchedAt":"2026-09-28T12:10:00Z","freshness":"sample","legs":[{"mode":"bus","origin":"Sample destination","destination":"Sample transfer","scheduledDeparture":"2026-09-28T14:10:00Z","status":"scheduled"},{"mode":"train","origin":"Sample transfer","destination":"Sample origin","scheduledDeparture":"2026-09-28T14:44:00Z","status":"scheduled"}]}
            """;

    private NextLegServer() {}

    public static void main(String[] args) throws IOException {
        String host = System.getenv().getOrDefault("NEXTLEG_HOST", "0.0.0.0");
        int port = Integer.parseInt(System.getenv().getOrDefault("NEXTLEG_PORT", "8080"));
        HttpServer server = HttpServer.create(new InetSocketAddress(host, port), 0);
        server.createContext("/", NextLegServer::handle);
        server.start();
        System.out.println("NextLeg sample service listening on " + host + ":" + port);
    }

    private static void handle(HttpExchange exchange) throws IOException {
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
        try {
            direction = requestedDirection(exchange.getRequestURI().getRawQuery());
        } catch (IllegalArgumentException exception) {
            send(exchange, 400, jsonError(exception.getMessage()));
            return;
        }
        switch (direction) {
            case "to_veghel" -> send(exchange, 200, TO_VEGHEL);
            case "to_blerick" -> send(exchange, 200, TO_BLERICK);
            default -> send(exchange, 400, "{\"error\":\"Invalid direction. Use to_veghel or to_blerick.\"}");
        }
    }

    private static String requestedDirection(String query) {
        if (query == null || query.isEmpty()) {
            throw new IllegalArgumentException("Missing required query parameter: direction.");
        }
        String direction = null;
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
            if (key.equals("direction")) {
                if (direction != null) {
                    throw new IllegalArgumentException("Use exactly one direction query parameter.");
                }
                direction = value;
            }
        }
        if (direction == null || direction.isBlank()) {
            throw new IllegalArgumentException("Missing required query parameter: direction.");
        }
        return direction;
    }

    private static String jsonError(String message) {
        String safeMessage = message.replace("\\", "\\\\").replace("\"", "\\\"");
        return "{\"error\":\"" + safeMessage + "\"}";
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
}
