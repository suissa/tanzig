const std = @import("std");
const zx = @import("../root.zig");
const types = @import("types.zig");

pub const Endpoint = enum { responses, chat_completions };

pub const Config = struct {
    api_key: []const u8,
    model: []const u8 = "gpt-5.2",
    base_url: []const u8 = "https://api.openai.com/v1",
    endpoint: Endpoint = .responses,
    temperature: ?f32 = null,
    max_output_tokens: ?u32 = null,
};

pub const Adapter = struct {
    config: Config,

    pub fn init(config: Config) Adapter {
        return .{ .config = config };
    }

    pub fn chat(self: Adapter, allocator: std.mem.Allocator, request: types.ChatRequest, emit: *const fn (types.StreamChunk, ?[]const u8) anyerror!void) !void {
        try types.validate(request);
        if (self.config.api_key.len == 0) return error.MissingApiKey;

        var body = std.ArrayList(u8).empty;
        defer body.deinit(allocator);
        var writer = body.writer(allocator);

        try writer.writeByte('{');
        try writeJsonString(writer, "model");
        try writer.writeAll(":");
        try writeJsonString(writer, request.model orelse self.config.model);
        try writer.writeAll(",\"stream\":true");

        if (self.config.endpoint == .responses) {
            try writer.writeAll(",\"input\":[");
            for (request.messages, 0..) |message, i| {
                if (i != 0) try writer.writeByte(',');
                try writer.writeByte('{');
                try writeJsonString(writer, "role");
                try writer.writeAll(":");
                try writeJsonString(writer, @tagName(message.role));
                try writer.writeAll(",\"content\":");
                try writeJsonString(writer, message.content);
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
            if (request.temperature orelse self.config.temperature) |temperature| {
                try writer.print(",\"temperature\":{d}", .{temperature});
            }
            if (request.max_output_tokens orelse self.config.max_output_tokens) |max_tokens| {
                try writer.print(",\"max_output_tokens\":{d}", .{max_tokens});
            }
        } else {
            try writer.writeAll(",\"messages\":[");
            for (request.messages, 0..) |message, i| {
                if (i != 0) try writer.writeByte(',');
                try writer.writeByte('{');
                try writeJsonString(writer, "role");
                try writer.writeAll(":");
                try writeJsonString(writer, @tagName(message.role));
                try writer.writeAll(",\"content\":");
                try writeJsonString(writer, message.content);
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
            if (request.temperature orelse self.config.temperature) |temperature| {
                try writer.print(",\"temperature\":{d}", .{temperature});
            }
            if (request.max_output_tokens orelse self.config.max_output_tokens) |max_tokens| {
                try writer.print(",\"max_tokens\":{d}", .{max_tokens});
            }
        }
        try writer.writeByte('}');

        const endpoint = switch (self.config.endpoint) {
            .responses => "/responses",
            .chat_completions => "/chat/completions",
        };
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.config.base_url, endpoint });
        defer allocator.free(url);

        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.config.api_key});
        defer allocator.free(auth);
        const headers = [_]zx.Fetch.RequestInit.Header{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "text/event-stream" },
        };

        var response = (try zx.fetch(.blocking, allocator, url, .{
            .method = .POST,
            .headers = &headers,
            .body = body.items,
            .timeout_ms = 120_000,
        })) orelse return error.ProviderError;
        defer response.deinit();

        if (!response.ok()) return error.ProviderError;
        const raw = try response.text();
        try parseSse(allocator, raw, request.thread_id, request.run_id, emit);
    }
};

pub fn openaiText(model: []const u8, api_key: []const u8) Adapter {
    return Adapter.init(.{ .model = model, .api_key = api_key, .endpoint = .responses });
}

pub fn openaiChatCompletions(model: []const u8, api_key: []const u8) Adapter {
    return Adapter.init(.{ .model = model, .api_key = api_key, .endpoint = .chat_completions });
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try std.json.stringify(value, .{}, writer);
}

fn parseSse(
    allocator: std.mem.Allocator,
    raw: []const u8,
    thread_id: ?[]const u8,
    run_id: ?[]const u8,
    emit: *const fn (types.StreamChunk, ?[]const u8) anyerror!void,
) !void {
    var started = false;
    var message_started = false;
    var message_id: []const u8 = "message-1";

    var lines = std.mem.splitSequence(u8, raw, "\n");
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trimSpace(line[5..]);
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) continue;

        const event_type = if (root.object.get("type")) |v| if (v == .string) v.string else "" else "";

        if (!started) {
            started = true;
            try emit(.{ .type = .RUN_STARTED, .timestamp = types.nowMs(), .threadId = thread_id, .runId = run_id }, null);
        }

        var delta: ?[]const u8 = null;
        if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
            if (root.object.get("delta")) |v| if (v == .string) delta = v.string;
        } else if (std.mem.eql(u8, event_type, "response.completed")) {
            if (root.object.get("response")) |response_value| {
                if (response_value == .object) {
                    if (response_value.object.get("id")) |id| if (id == .string) message_id = id.string;
                }
            }
        } else if (root.object.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                const choice = choices.array.items[0];
                if (choice == .object) if (choice.object.get("delta")) |d| if (d == .object) if (d.object.get("content")) |c| if (c == .string) delta = c.string;
            }
        }

        if (delta) |text| {
            if (!message_started) {
                message_started = true;
                try emit(.{ .type = .TEXT_MESSAGE_START, .timestamp = types.nowMs(), .threadId = thread_id, .runId = run_id, .messageId = message_id }, null);
            }
            try emit(.{ .type = .TEXT_MESSAGE_CONTENT, .timestamp = types.nowMs(), .threadId = thread_id, .runId = run_id, .messageId = message_id, .delta = text }, null);
        }

        if (std.mem.eql(u8, event_type, "response.completed") or (root.object.get("choices") != null and std.mem.eql(u8, event_type, ""))) {
            if (message_started) try emit(.{ .type = .TEXT_MESSAGE_END, .timestamp = types.nowMs(), .threadId = thread_id, .runId = run_id, .messageId = message_id }, null);
            try emit(.{ .type = .RUN_FINISHED, .timestamp = types.nowMs(), .threadId = thread_id, .runId = run_id }, null);
            return;
        }
    }

    if (started) {
        if (message_started) try emit(.{ .type = .TEXT_MESSAGE_END, .timestamp = types.nowMs(), .threadId = thread_id, .runId = run_id, .messageId = message_id }, null);
        try emit(.{ .type = .RUN_FINISHED, .timestamp = types.nowMs(), .threadId = thread_id, .runId = run_id }, null);
    }
}
