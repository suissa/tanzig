# MCP server and route bridges

Ziex uses one capability registry to avoid duplicating business logic across HTTP, WebSocket and MCP stdio.

## Register an existing HTTP operation

Initialize a Registry and register the same handler that the HTTP route calls. The handler is not copied, and no duplicate HTTP route is created. Each tool declares a JSON Schema inputSchema and an explicit existing http_path.

## WebSocket

For each incoming text frame, call handleWebSocket with the registry, allocator, authenticated principal, route path and frame. Send a non-empty return value as a text frame. Supported MCP methods include initialize, ping, tools/list and tools/call. Use the framework's existing WebSocket route and session/authentication lifecycle.

## stdio

handleStdioFrame handles a decoded JSON-RPC payload. parseStdioFrame and writeStdioFrame provide Content-Length framing helpers for a host-owned stdin/stdout loop. Keep logs on stderr; stdout is reserved for MCP frames. The host process owns the read loop and graceful shutdown.

## Boundaries

- Existing HTTP routes remain authoritative; this module does not start another HTTP server or register duplicate paths.
- One handler and one authorization path can serve HTTP, WebSocket and stdio.
- Only explicitly registered capabilities are advertised as tools. Arbitrary routes are not automatically exposed.
- Mapping must be explicit because pages, mutations and authentication endpoints should not automatically become tools.
- The stdio helpers are transport primitives, not an OS-specific process launcher.
