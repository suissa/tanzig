const std = @import("std");

pub const Role = enum { system, user, assistant, tool };

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub const ChatRequest = struct {
    messages: []const Message,
    thread_id: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    temperature: ?f32 = null,
    max_output_tokens: ?u32 = null,
};

pub const StreamType = enum {
    RUN_STARTED,
    TEXT_MESSAGE_START,
    TEXT_MESSAGE_CONTENT,
    TEXT_MESSAGE_END,
    RUN_FINISHED,
    RUN_ERROR,
};

pub const StreamChunk = struct {
    type: StreamType,
    timestamp: i64,
    threadId: ?[]const u8 = null,
    runId: ?[]const u8 = null,
    messageId: ?[]const u8 = null,
    delta: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const ChatError = error{
    InvalidRequest,
    EmptyMessage,
    MessageTooLong,
    TooManyMessages,
    MissingApiKey,
    ProviderError,
    InvalidProviderResponse,
    UnsupportedProvider,
    OutOfMemory,
};

pub fn validate(request: ChatRequest) ChatError!void {
    if (request.messages.len == 0 or request.messages.len > 100) return error.InvalidRequest;

    for (request.messages) |message| {
        if (message.content.len == 0) return error.EmptyMessage;
        if (message.content.len > 32 * 1024) return error.MessageTooLong;
    }
}

pub fn deinitMessages(allocator: std.mem.Allocator, messages: []Message) void {
    for (messages) |message| allocator.free(message.content);
    allocator.free(messages);
}

pub fn nowMs() i64 {
    return std.time.milliTimestamp();
}
