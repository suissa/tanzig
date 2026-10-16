const std = @import("std");
const zx = @import("../root.zig");
const types = @import("types.zig");
const chat_mod = @import("chat.zig");

pub const WebSocketConfig = struct {
    adapter: anytype,
    max_message_bytes: usize = 32 * 1024,
};

const WireMessage = struct {
    role: types.Role = .user,
    content: []const u8,
};

const WireRequest = struct {
    messages: ?[]WireMessage = null,
    message: ?[]const u8 = null,
    threadId: ?[]const u8 = null,
    runId: ?[]const u8 = null,
    model: ?[]const u8 = null,
    temperature: ?f32 = null,
    max_output_tokens: ?u32 = null,
};

/// Handle one TanStack AI-style WebSocket frame.
///
/// The browser keeps one socket open and sends one RunAgentInput-like JSON
/// frame per turn. Each generated StreamChunk is written back as JSON.
pub fn handle(config: anytype, socket: zx.Socket, raw_message: []const u8, allocator: std.mem.Allocator) !void {
    if (raw_message.len == 0 or raw_message.len > config.max_message_bytes) {
        try sendError(socket, allocator, "invalid_request", "message is empty or too large");
        return error.InvalidRequest;
    }

    var parsed = std.json.parseFromSlice(WireRequest, allocator, raw_message, .{ .ignore_unknown_fields = true }) catch {
        try sendError(socket, allocator, "invalid_json", "invalid chat frame");
        return error.InvalidRequest;
    };
    defer parsed.deinit();

    const wire = parsed.value;
    var messages = std.ArrayList(types.Message).empty;
    defer messages.deinit(allocator);

    if (wire.messages) |input_messages| {
        if (input_messages.len == 0) {
            try sendError(socket, allocator, "invalid_request", "messages cannot be empty");
            return error.InvalidRequest;
        }
        for (input_messages) |message| {
            if (message.content.len == 0) {
                try sendError(socket, allocator, "invalid_request", "message content cannot be empty");
                return error.InvalidRequest;
            }
            try messages.append(allocator, .{ .role = message.role, .content = message.content });
        }
    } else if (wire.message) |message| {
        if (message.len == 0) {
            try sendError(socket, allocator, "invalid_request", "message content cannot be empty");
            return error.InvalidRequest;
        }
        try messages.append(allocator, .{ .role = .user, .content = message });
    } else {
        try sendError(socket, allocator, "invalid_request", "expected messages or message");
        return error.InvalidRequest;
    }

    const request = types.ChatRequest{
        .messages = messages.items,
        .thread_id = wire.threadId,
        .run_id = wire.runId,
        .model = wire.model,
        .temperature = wire.temperature,
        .max_output_tokens = wire.max_output_tokens,
    };

    types.validate(request) catch |err| {
        try sendError(socket, allocator, "validation_error", @errorName(err));
        return err;
    };

    const Emitter = struct {
        socket: zx.Socket,
        allocator: std.mem.Allocator,

        fn emit(self: *@This(), chunk: types.StreamChunk, _: ?[]const u8) !void {
            var payload = std.ArrayList(u8).empty;
            defer payload.deinit(self.allocator);
            try std.json.stringify(chunk, .{}, payload.writer(self.allocator));
            try self.socket.write(payload.items);
        }
    };

    var emitter = Emitter{ .socket = socket, .allocator = allocator };
    try chat_mod.chat(.{ .adapter = config.adapter, .messages = messages.items, .thread_id = request.thread_id, .run_id = request.run_id, .model = request.model, .temperature = request.temperature, .max_output_tokens = request.max_output_tokens }, allocator, Emitter.emit);
}

fn sendError(socket: zx.Socket, allocator: std.mem.Allocator, code: []const u8, message: []const u8) !void {
    const Chunk = struct {
        type: types.StreamType = .RUN_ERROR,
        timestamp: i64,
        message: []const u8,
        error: struct { code: []const u8, message: []const u8 },
    };
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    try std.json.stringify(Chunk{ .timestamp = types.nowMs(), .message = message, .error = .{ .code = code, .message = message } }, .{}, payload.writer(allocator));
    try socket.write(payload.items);
}

/// Adapt the framework's generated ServerApp.SocketHandler signature.
pub fn handler(config: anytype) zx.server.App.SocketHandler {
    const Wrapper = struct {
        var cfg: @TypeOf(config) = config;

        fn run(socket: zx.Socket, message: []const u8, message_type: zx.SocketMessageType, _: ?[]const u8, allocator: std.mem.Allocator, _: std.mem.Allocator, _: std.Io) anyerror!void {
            if (message_type != .text) return error.InvalidRequest;
            return handle(cfg, socket, message, allocator);
        }
    };
    return Wrapper.run;
}
