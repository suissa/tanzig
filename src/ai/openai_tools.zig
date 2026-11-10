const std = @import("std");
const utils = @import("utils.zig");

const CallBuilder = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *CallBuilder, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.arguments.deinit(allocator);
    }
};

pub const ParsedToolResponse = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    calls: []utils.ToolCall,

    pub fn deinit(self: *ParsedToolResponse) void {
        self.allocator.free(self.text);
        for (self.calls) |call| {
            self.allocator.free(@constCast(call.id));
            self.allocator.free(@constCast(call.name));
            self.allocator.free(@constCast(call.arguments_json));
        }
        self.allocator.free(self.calls);
        self.* = undefined;
    }
};

fn duplicateCall(allocator: std.mem.Allocator, builder: CallBuilder) !utils.ToolCall {
    const id = try allocator.dupe(u8, builder.id.items);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, builder.name.items);
    errdefer allocator.free(name);
    const arguments_json = try allocator.dupe(u8, builder.arguments.items);
    return .{ .id = id, .name = name, .arguments_json = arguments_json };
}

/// Decode a complete Chat Completions SSE body into accumulated assistant text
/// and function calls. The returned strings are owned by ParsedToolResponse.
/// This parser intentionally handles the Chat Completions delta protocol only.
pub fn parseChatCompletionsSse(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !ParsedToolResponse {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);
    var builders = std.ArrayList(CallBuilder).empty;
    defer {
        for (builders.items) |*builder| builder.deinit(allocator);
        builders.deinit(allocator);
    }

    var lines = std.mem.splitSequence(u8, raw, "\n");
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line[5..], " \t\r");
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const choices = parsed.value.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;
        const choice = choices.array.items[0];
        if (choice != .object) continue;
        const delta = choice.object.get("delta") orelse continue;
        if (delta != .object) continue;

        if (delta.object.get("content")) |content_value| {
            if (content_value == .string) try text.appendSlice(allocator, content_value.string);
        }
        const fragments = delta.object.get("tool_calls") orelse continue;
        if (fragments != .array) continue;
        for (fragments.array.items) |fragment| {
            if (fragment != .object) continue;
            const index_value = fragment.object.get("index") orelse continue;
            if (index_value != .integer or index_value.integer < 0) continue;
            const index: usize = @intCast(index_value.integer);
            while (builders.items.len <= index) try builders.append(allocator, .{});
            const builder = &builders.items[index];

            if (fragment.object.get("id")) |id_value| {
                if (id_value == .string) try builder.id.appendSlice(allocator, id_value.string);
            }
            if (fragment.object.get("function")) |function_value| {
                if (function_value == .object) {
                    if (function_value.object.get("name")) |name_value| {
                        if (name_value == .string) try builder.name.appendSlice(allocator, name_value.string);
                    }
                    if (function_value.object.get("arguments")) |args_value| {
                        if (args_value == .string) try builder.arguments.appendSlice(allocator, args_value.string);
                    }
                }
            }
        }
    }

    const calls = try allocator.alloc(utils.ToolCall, builders.items.len);
    errdefer allocator.free(calls);
    var initialized: usize = 0;
    errdefer {
        for (calls[0..initialized]) |call| {
            allocator.free(@constCast(call.id));
            allocator.free(@constCast(call.name));
            allocator.free(@constCast(call.arguments_json));
        }
    }
    for (builders.items, 0..) |builder, i| {
        calls[i] = try duplicateCall(allocator, builder);
        initialized += 1;
    }

    return .{
        .allocator = allocator,
        .text = try text.toOwnedSlice(allocator),
        .calls = calls,
    };
}

test "parses fragmented OpenAI tool call deltas and text" {
    const raw =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Checking \",\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"get_\",\"arguments\":\"{\"}}]}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"weather\",\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"weather\",\"arguments\":\"}\"}}]}}]}\n" ++
        "data: [DONE]\n";
    var response = try parseChatCompletionsSse(std.testing.allocator, raw);
    defer response.deinit();
    try std.testing.expectEqualStrings("Checking weather", response.text);
    try std.testing.expectEqual(@as(usize, 1), response.calls.len);
    try std.testing.expectEqualStrings("call_1", response.calls[0].id);
    try std.testing.expectEqualStrings("get_weather", response.calls[0].name);
    try std.testing.expectEqualStrings("{}", response.calls[0].arguments_json);
}

test "empty tool stream returns empty owned collections" {
    var response = try parseChatCompletionsSse(std.testing.allocator, "data: [DONE]\n");
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 0), response.calls.len);
    try std.testing.expectEqual(@as(usize, 0), response.text.len);
}
