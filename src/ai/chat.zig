const std = @import("std");
const types = @import("types.zig");

pub const ChatOptions = struct {
    adapter: anytype,
    messages: []const types.Message,
    thread_id: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
};

/// TanStack AI-compatible chat primitive.
///
/// The adapter is provider-specific (for example openaiText()) while this
/// function owns validation and the framework-neutral streaming lifecycle.
pub fn chat(options: anytype, allocator: std.mem.Allocator, emit: *const fn (types.StreamChunk, ?[]const u8) anyerror!void) !void {
    const request = types.ChatRequest{
        .messages = options.messages,
        .thread_id = options.thread_id,
        .run_id = options.run_id,
        .model = if (@hasField(@TypeOf(options), "model")) options.model else null,
        .temperature = if (@hasField(@TypeOf(options), "temperature")) options.temperature else null,
        .max_output_tokens = if (@hasField(@TypeOf(options), "max_output_tokens")) options.max_output_tokens else null,
    };
    types.validate(request) catch |err| {
        try emit(.{ .type = .RUN_ERROR, .timestamp = types.nowMs(), .threadId = request.thread_id, .runId = request.run_id, .message = @errorName(err) }, null);
        return err;
    };
    try options.adapter.chat(allocator, request, emit);
}

/// Collect a streamed chat into a single response string.
pub fn streamToText(allocator: std.mem.Allocator, options: anytype) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    const Emitter = struct {
        list: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        fn emit(self: *@This(), chunk: types.StreamChunk, _: ?[]const u8) !void {
            if (chunk.type == .TEXT_MESSAGE_CONTENT) if (chunk.delta) |delta| try self.list.appendSlice(self.allocator, delta);
        }
    };
    var emitter = Emitter{ .list = &output, .allocator = allocator };
    try chat(options, allocator, Emitter.emit);
    return output.toOwnedSlice(allocator);
}
