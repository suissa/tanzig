//! MCP (Model Context Protocol) bridge for Ziex routes.
//!
//! Register an application capability once, then expose that same handler as
//! an ordinary HTTP route, a WebSocket JSON-RPC channel, and an MCP stdio server.
//! This module does not create a second router: the host supplies existing
//! route handlers through Registry.register().
const std = @import("std");

pub const protocol_version = "2025-03-26";
pub const default_server_name = "ziex";
pub const default_server_version = "0.1.0";

pub const Transport = enum { http, websocket, stdio };
pub const Error = error{ InvalidJson, InvalidRequest, MethodNotFound, ToolNotFound, InvalidParams, HandlerFailed, OutputTooLarge, UnsupportedTransport };

pub const RequestContext = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    principal: ?[]const u8 = null,
    source_path: ?[]const u8 = null,
};

pub const ToolHandler = *const fn (context: RequestContext, arguments: std.json.Value) anyerror!std.json.Value;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
    handler: ToolHandler,
    http_path: []const u8,
    mcp_enabled: bool = true,
    websocket_enabled: bool = true,
};

pub const Config = struct {
    name: []const u8 = default_server_name,
    version: []const u8 = default_server_version,
    max_message_bytes: usize = 1024 * 1024,
    max_tools: usize = 256,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    config: Config,
    tools: std.ArrayList(Tool) = .empty,

    pub fn init(allocator: std.mem.Allocator, config: Config) Registry {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Registry) void {
        self.tools.deinit(self.allocator);
    }

    /// Register the same operation used by an existing HTTP route.
    pub fn register(self: *Registry, tool: Tool) !void {
        if (self.tools.items.len >= self.config.max_tools) return Error.OutputTooLarge;
        if (!validName(tool.name) or tool.http_path.len == 0) return Error.InvalidParams;
        for (self.tools.items) |existing| {
            if (std.mem.eql(u8, existing.name, tool.name) or std.mem.eql(u8, existing.http_path, tool.http_path))
                return Error.InvalidParams;
        }
        try self.tools.append(self.allocator, tool);
    }

    pub fn find(self: *const Registry, name: []const u8) ?Tool {
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }

    pub fn handleJsonRpc(self: *Registry, allocator: std.mem.Allocator, transport: Transport, principal: ?[]const u8, source_path: ?[]const u8, raw: []const u8) ![]u8 {
        if (raw.len > self.config.max_message_bytes) return Error.OutputTooLarge;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return Error.InvalidJson;
        defer parsed.deinit();
        const request = parsed.value;
        if (request != .object) return Error.InvalidRequest;
        const method_value = request.object.get("method") orelse return Error.InvalidRequest;
        if (method_value != .string) return Error.InvalidRequest;
        const method = method_value.string;
        const id = request.object.get("id");
        const params = request.object.get("params") orelse .{ .object = std.json.ObjectMap.init(allocator) };

        if (std.mem.eql(u8, method, "notifications/initialized") or (id == null and std.mem.startsWith(u8, method, "notifications/")))
            return allocator.dupe(u8, "");

        var result: std.json.Value = .null;
        if (std.mem.eql(u8, method, "initialize")) {
            result = try self.initializeResult(allocator);
        } else if (std.mem.eql(u8, method, "ping")) {
            result = .{ .object = std.json.ObjectMap.init(allocator) };
        } else if (std.mem.eql(u8, method, "tools/list")) {
            result = try self.toolsList(allocator);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            result = try self.callTool(allocator, transport, principal, source_path, params);
        } else {
            return try rpcError(allocator, id, -32601, "Method not found");
        }
        return try rpcResult(allocator, id, result);
    }

    fn initializeResult(self: *const Registry, allocator: std.mem.Allocator) !std.json.Value {
        var capabilities = std.json.ObjectMap.init(allocator);
        var tools_cap = std.json.ObjectMap.init(allocator);
        try tools_cap.put("listChanged", .{ .bool = false });
        try capabilities.put("tools", .{ .object = tools_cap });
        var server_info = std.json.ObjectMap.init(allocator);
        try server_info.put("name", .{ .string = self.config.name });
        try server_info.put("version", .{ .string = self.config.version });
        var result = std.json.ObjectMap.init(allocator);
        try result.put("protocolVersion", .{ .string = protocol_version });
        try result.put("capabilities", .{ .object = capabilities });
        try result.put("serverInfo", .{ .object = server_info });
        return .{ .object = result };
    }

    fn toolsList(self: *const Registry, allocator: std.mem.Allocator) !std.json.Value {
        var list = std.json.Array.init(allocator);
        for (self.tools.items) |tool| {
            if (!tool.mcp_enabled) continue;
            var item = std.json.ObjectMap.init(allocator);
            try item.put("name", .{ .string = tool.name });
            try item.put("description", .{ .string = tool.description });
            try item.put("inputSchema", tool.input_schema);
            try list.append(.{ .object = item });
        }
        var result = std.json.ObjectMap.init(allocator);
        try result.put("tools", .{ .array = list });
        return .{ .object = result };
    }

    fn callTool(self: *Registry, allocator: std.mem.Allocator, transport: Transport, principal: ?[]const u8, source_path: ?[]const u8, params: std.json.Value) !std.json.Value {
        if (params != .object) return Error.InvalidParams;
        const name_value = params.object.get("name") orelse return Error.InvalidParams;
        if (name_value != .string) return Error.InvalidParams;
        const tool = self.find(name_value.string) orelse return try toolError(allocator, "Unknown tool");
        if (transport == .websocket and !tool.websocket_enabled) return try toolError(allocator, "Tool is not available on WebSocket");
        if (transport != .http and !tool.mcp_enabled) return try toolError(allocator, "Tool is not exposed over MCP");
        const args = params.object.get("arguments") orelse .{ .object = std.json.ObjectMap.init(allocator) };
        const context = RequestContext{ .allocator = allocator, .transport = transport, .principal = principal, .source_path = source_path orelse tool.http_path };
        const value = tool.handler(context, args) catch return try toolError(allocator, "Tool execution failed");
        const text_value = try std.json.Stringify.valueAlloc(allocator, value, .{});
        var item = std.json.ObjectMap.init(allocator);
        try item.put("type", .{ .string = "text" });
        try item.put("text", .{ .string = text_value });
        var content = std.json.Array.init(allocator);
        try content.append(.{ .object = item });
        var result = std.json.ObjectMap.init(allocator);
        try result.put("content", .{ .array = content });
        try result.put("structuredContent", value);
        try result.put("isError", .{ .bool = false });
        return .{ .object = result };
    }
};

/// Pass each WebSocket text frame here; send non-empty output as a text frame.
pub fn handleWebSocket(registry: *Registry, allocator: std.mem.Allocator, principal: ?[]const u8, route_path: []const u8, frame: []const u8) ![]u8 {
    return registry.handleJsonRpc(allocator, .websocket, principal, route_path, frame);
}

/// Handle a decoded JSON-RPC payload from the stdio transport.
pub fn handleStdioFrame(registry: *Registry, allocator: std.mem.Allocator, frame: []const u8) ![]u8 {
    return registry.handleJsonRpc(allocator, .stdio, null, null, frame);
}

/// Write an MCP Content-Length frame. Keep diagnostics off stdout.
pub fn writeStdioFrame(writer: anytype, payload: []const u8) !void {
    if (payload.len == 0) return;
    try writer.print("Content-Length: {d}\r\n\r\n", .{payload.len});
    try writer.writeAll(payload);
    try writer.flush();
}

/// Decode one Content-Length frame from buffered bytes.
pub fn parseStdioFrame(allocator: std.mem.Allocator, bytes: []const u8, max_bytes: usize) !struct { payload: []u8, consumed: usize } {
    const header_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return Error.InvalidRequest;
    const header = bytes[0..header_end];
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    const first = lines.next() orelse return Error.InvalidRequest;
    if (!std.mem.startsWith(u8, first, "Content-Length:")) return Error.InvalidRequest;
    const length_text = std.mem.trim(u8, first["Content-Length:".len..], " \t");
    const length = std.fmt.parseInt(usize, length_text, 10) catch return Error.InvalidRequest;
    if (length > max_bytes) return Error.OutputTooLarge;
    const payload_start = header_end + 4;
    if (bytes.len - payload_start < length) return Error.InvalidRequest;
    return .{ .payload = try allocator.dupe(u8, bytes[payload_start .. payload_start + length]), .consumed = payload_start + length };
}

fn rpcResult(allocator: std.mem.Allocator, id: ?std.json.Value, result: std.json.Value) ![]u8 {
    var object = std.json.ObjectMap.init(allocator);
    try object.put("jsonrpc", .{ .string = "2.0" });
    try object.put("id", id orelse .null);
    try object.put("result", result);
    return try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
}

fn rpcError(allocator: std.mem.Allocator, id: ?std.json.Value, code: i64, message: []const u8) ![]u8 {
    var error_obj = std.json.ObjectMap.init(allocator);
    try error_obj.put("code", .{ .integer = code });
    try error_obj.put("message", .{ .string = message });
    var object = std.json.ObjectMap.init(allocator);
    try object.put("jsonrpc", .{ .string = "2.0" });
    try object.put("id", id orelse .null);
    try object.put("error", .{ .object = error_obj });
    return try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{});
}

fn toolError(allocator: std.mem.Allocator, message: []const u8) !std.json.Value {
    var item = std.json.ObjectMap.init(allocator);
    try item.put("type", .{ .string = "text" });
    try item.put("text", .{ .string = message });
    var content = std.json.Array.init(allocator);
    try content.append(.{ .object = item });
    var result = std.json.ObjectMap.init(allocator);
    try result.put("content", .{ .array = content });
    try result.put("isError", .{ .bool = true });
    return .{ .object = result };
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    }
    return true;
}

test "stdio framing round-trips a payload" {
    const allocator = std.testing.allocator;
    const input = "Content-Length: 2\r\n\r\n{}";
    const parsed = try parseStdioFrame(allocator, input, 1024);
    defer allocator.free(parsed.payload);
    try std.testing.expectEqualStrings("{}", parsed.payload);
    try std.testing.expectEqual(@as(usize, input.len), parsed.consumed);
}

test "tool names are constrained" {
    try std.testing.expect(validName("orders.list"));
    try std.testing.expect(!validName("orders/list"));
}
