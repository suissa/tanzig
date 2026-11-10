const std = @import("std");
const utils = @import("utils.zig");

pub const ModelReply = struct {
    text: ?[]const u8 = null,
    tool_calls: []const utils.ToolCall = &.{},
};

pub const ModelInvoker = struct {
    context: *anyopaque,
    invoke_fn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        tools: []const utils.Tool,
        previous_results: []const utils.ToolResult,
    ) anyerror!ModelReply,

    pub fn invoke(
        self: ModelInvoker,
        allocator: std.mem.Allocator,
        tools: []const utils.Tool,
        previous_results: []const utils.ToolResult,
    ) anyerror!ModelReply {
        return self.invoke_fn(self.context, allocator, tools, previous_results);
    }
};

pub const RunResult = struct {
    text: ?[]const u8,
    tool_rounds: usize,
    tool_calls: usize,
};

/// Runs a provider-neutral tool loop. The invoker owns provider conversation
/// state and receives the preceding batch results before each subsequent turn.
/// Model/tool output slices are borrowed; failed result payloads are released
/// here after the next model invocation has consumed them.
pub fn runWithTools(
    allocator: std.mem.Allocator,
    registered_tools: []const utils.Tool,
    invoker: ModelInvoker,
    options: utils.RunOptions,
) !RunResult {
    var previous_results: []utils.ToolResult = @constCast(&[_]utils.ToolResult{});
    var owned_results = false;
    defer {
        if (owned_results) {
            for (previous_results) |result| {
                if (result.failed) allocator.free(@constCast(result.output));
            }
            allocator.free(previous_results);
        }
    }

    var rounds: usize = 0;
    var total_calls: usize = 0;
    while (true) {
        const reply = try invoker.invoke(allocator, registered_tools, previous_results);
        if (reply.tool_calls.len == 0) {
            return .{ .text = reply.text, .tool_rounds = rounds, .tool_calls = total_calls };
        }
        if (rounds >= options.max_recursive_tool_runs) return error.MaxToolRoundsExceeded;

        if (owned_results) {
            for (previous_results) |result| {
                if (result.failed) allocator.free(@constCast(result.output));
            }
            allocator.free(previous_results);
            previous_results = @constCast(&[_]utils.ToolResult{});
            owned_results = false;
        }

        previous_results = try utils.executeToolCalls(
            allocator,
            registered_tools,
            reply.tool_calls,
            options,
        );
        owned_results = true;
        rounds += 1;
        total_calls += reply.tool_calls.len;
    }
}

test "runWithTools feeds tool results into the next model turn" {
    const State = struct {
        step: usize = 0,
        fn invoke(
            raw: *anyopaque,
            allocator: std.mem.Allocator,
            _: []const utils.Tool,
            previous: []const utils.ToolResult,
        ) anyerror!ModelReply {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.step += 1;
            if (self.step == 1) return .{
                .tool_calls = &.{.{ .id = "call-1", .name = "echo", .arguments_json = "{\"ok\":true}" }},
            };
            try std.testing.expectEqual(@as(usize, 1), previous.len);
            try std.testing.expectEqualStrings("{\"ok\":true}", previous[0].output);
            _ = allocator;
            return .{ .text = "finished" };
        }
    };
    const Echo = struct {
        fn call(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
            _ = allocator;
            return @constCast(args);
        }
    };
    var state = State{};
    const tools = [_]utils.Tool{.{
        .name = "echo",
        .description = "Echo input",
        .parameters_json = "{\"type\":\"object\"}",
        .function = Echo.call,
    }};
    const result = try runWithTools(std.testing.allocator, &tools, .{
        .context = &state,
        .invoke_fn = State.invoke,
    }, .{ .max_recursive_tool_runs = 2 });
    try std.testing.expectEqualStrings("finished", result.text.?);
    try std.testing.expectEqual(@as(usize, 1), result.tool_rounds);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls);
}

test "runWithTools enforces recursive tool round limit" {
    const State = struct {
        fn invoke(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: []const utils.Tool,
            _: []const utils.ToolResult,
        ) anyerror!ModelReply {
            return .{ .tool_calls = &.{.{ .id = "c", .name = "missing", .arguments_json = "{}" }} };
        }
    };
    var state: u8 = 0;
    try std.testing.expectError(error.MaxToolRoundsExceeded, runWithTools(
        std.testing.allocator,
        &.{},
        .{ .context = &state, .invoke_fn = State.invoke },
        .{ .max_recursive_tool_runs = 1 },
    ));
}
