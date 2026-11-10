/// Cloudflare AI Utils-compatible tool primitives for Tanzig.
///
/// This module intentionally separates provider-specific inference from tool
/// orchestration. A caller supplies the model invocation and tool execution
/// callbacks, allowing the same tool definitions to work with OpenAI-compatible
/// endpoints, Workers AI adapters, and local inference providers.
const std = @import("std");

pub const ToolFunction = *const fn (allocator: std.mem.Allocator, arguments_json: []const u8) anyerror![]u8;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    function: ToolFunction,
};

/// Equivalent to the TypeScript tool() helper: preserves a typed tool
/// declaration while keeping registration explicit and allocation-free.
pub fn tool(definition: Tool) Tool {
    return definition;
}

pub const TrimOptions = struct {
    max_tools: usize = 8,
};

/// Select tools by lexical relevance to the latest user request. The original
/// order is retained for equal scores and the returned slice uses the caller's
/// allocator. This is a deterministic, provider-independent alternative to
/// asking a second model to select tools.
pub fn autoTrimTools(
    allocator: std.mem.Allocator,
    tools: []const Tool,
    user_prompt: []const u8,
    options: TrimOptions,
) std.mem.Allocator.Error![]const Tool {
    const limit = @min(options.max_tools, tools.len);
    if (limit == 0) return allocator.alloc(Tool, 0);

    const Ranked = struct { index: usize, score: usize };
    const ranked = try allocator.alloc(Ranked, tools.len);
    defer allocator.free(ranked);

    for (tools, 0..) |item, i| {
        ranked[i] = .{ .index = i, .score = relevance(item, user_prompt) };
    }
    // Stable insertion sort avoids a dependency on unstable sort behavior.
    for (1..ranked.len) |i| {
        const current = ranked[i];
        var j = i;
        while (j > 0 and ranked[j - 1].score < current.score) : (j -= 1) {
            ranked[j] = ranked[j - 1];
        }
        ranked[j] = current;
    }

    const selected = try allocator.alloc(Tool, limit);
    for (ranked[0..limit], 0..) |entry, i| selected[i] = tools[entry.index];
    return selected;
}

fn relevance(tool_def: Tool, prompt: []const u8) usize {
    var score: usize = 0;
    var words = std.mem.tokenizeAny(u8, prompt, " \t\r\n.,!?;:()[]{}\"'");
    while (words.next()) |word| {
        if (word.len < 3) continue;
        if (containsIgnoreCase(tool_def.name, word)) score += 4;
        if (containsIgnoreCase(tool_def.description, word)) score += 2;
    }
    return score;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub const RunOptions = struct {
    strict_validation: bool = false,
    max_recursive_tool_runs: usize = 1,
    stream_final_response: bool = false,
    verbose: bool = false,
};

/// Validates that a model-provided tool argument payload is a JSON object.
/// Full JSON-Schema validation is intentionally delegated to a schema validator
/// supplied by the application; this guard rejects malformed/non-object input.
pub fn validateToolArguments(allocator: std.mem.Allocator, arguments_json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
    defer parsed.deinit();
    switch (parsed.value) {
        .object => {},
        else => return error.InvalidToolArguments,
    }
}

test "tool helper preserves the definition" {
    const noop = struct {
        fn call(_: std.mem.Allocator, _: []const u8) anyerror![]u8 {
            return "";
        }
    }.call;
    const definition = Tool{
        .name = "weather",
        .description = "Gets weather for a city",
        .parameters_json = "{\"type\":\"object\"}",
        .function = noop,
    };
    try std.testing.expectEqualStrings("weather", tool(definition).name);
}

test "argument validation requires a JSON object" {
    const allocator = std.testing.allocator;
    try validateToolArguments(allocator, "{\"city\":\"Recife\"}");
    try std.testing.expectError(error.InvalidToolArguments, validateToolArguments(allocator, "[]"));
}

test "auto trim favors relevant tool descriptions" {
    const noop = struct {
        fn call(_: std.mem.Allocator, _: []const u8) anyerror![]u8 {
            return "";
        }
    }.call;
    const definitions = [_]Tool{
        .{ .name = "get-weather", .description = "Gets current weather for a city", .parameters_json = "{}", .function = noop },
        .{ .name = "create-event", .description = "Creates a calendar event", .parameters_json = "{}", .function = noop },
    };
    const selected = try autoTrimTools(std.testing.allocator, &definitions, "weather in Recife", .{ .max_tools = 1 });
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("get-weather", selected[0].name);
}

/// One function call requested by a model. String fields are borrowed for the
/// duration of executeToolCalls and may point into the provider response.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

/// Result for one call. output is borrowed from the tool callback on success;
/// on dispatch/validation failure it is allocated from the supplied allocator.
pub const ToolResult = struct {
    id: []const u8,
    name: []const u8,
    output: []const u8,
    failed: bool = false,
};

/// Execute a complete model tool-call batch in order. Unknown tools and strict
/// argument-validation failures become per-call error results, so one bad call
/// does not prevent independent calls in the same batch from running.
/// Successful callbacks own the lifetime policy of their returned byte slice.
pub fn executeToolCalls(
    allocator: std.mem.Allocator,
    registered_tools: []const Tool,
    calls: []const ToolCall,
    options: RunOptions,
) ![]ToolResult {
    const results = try allocator.alloc(ToolResult, calls.len);
    var initialized: usize = 0;
    errdefer {
        for (results[0..initialized]) |result| {
            if (result.failed) allocator.free(@constCast(result.output));
        }
        allocator.free(results);
    }

    for (calls, 0..) |call, i| {
        const selected = findTool(registered_tools, call.name) orelse {
            results[i] = .{
                .id = call.id,
                .name = call.name,
                .output = try allocator.dupe(u8, "{\"error\":\"UnknownTool\"}"),
                .failed = true,
            };
            initialized = i + 1;
            continue;
        };

        if (options.strict_validation) {
            validateToolArguments(allocator, call.arguments_json) catch {
                results[i] = .{
                    .id = call.id,
                    .name = call.name,
                    .output = try allocator.dupe(u8, "{\"error\":\"InvalidToolArguments\"}"),
                    .failed = true,
                };
                initialized = i + 1;
                continue;
            };
        }

        const output = selected.function(allocator, call.arguments_json) catch |err| {
            results[i] = .{
                .id = call.id,
                .name = call.name,
                .output = try std.fmt.allocPrint(allocator, "{{\"error\":\"ToolExecutionFailed\",\"reason\":\"{s}\"}}", .{@errorName(err)}),
                .failed = true,
            };
            initialized = i + 1;
            continue;
        };
        results[i] = .{
            .id = call.id,
            .name = call.name,
            .output = output,
            .failed = false,
        };
        initialized += 1;
    }
    return results;
}

fn findTool(tools: []const Tool, name: []const u8) ?Tool {
    for (tools) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

test "executeToolCalls runs multiple calls and preserves call ids" {
    const callbacks = struct {
        fn echo(allocator: std.mem.Allocator, args: []const u8) anyerror![]u8 {
            return allocator.dupe(u8, args);
        }
    };
    const registered = [_]Tool{
        .{ .name = "echo", .description = "Echo arguments", .parameters_json = "{\"type\":\"object\"}", .function = callbacks.echo },
    };
    const calls = [_]ToolCall{
        .{ .id = "call-1", .name = "echo", .arguments_json = "{\"value\":1}" },
        .{ .id = "call-2", .name = "missing", .arguments_json = "{}" },
    };
    const results = try executeToolCalls(std.testing.allocator, &registered, &calls, .{});
    defer {
        for (results) |result| {
            if (result.failed) std.testing.allocator.free(@constCast(result.output));
        }
        std.testing.allocator.free(@constCast(results[0].output));
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqualStrings("call-1", results[0].id);
    try std.testing.expectEqualStrings("{\"value\":1}", results[0].output);
    try std.testing.expect(!results[0].failed);
    try std.testing.expect(results[1].failed);
    try std.testing.expectEqualStrings("{\"error\":\"UnknownTool\"}", results[1].output);
}

test "executeToolCalls rejects malformed arguments in strict mode" {
    const callbacks = struct {
        fn noop(_: std.mem.Allocator, _: []const u8) anyerror![]u8 {
            return "{}";
        }
    };
    const registered = [_]Tool{
        .{ .name = "noop", .description = "No operation", .parameters_json = "{}", .function = callbacks.noop },
    };
    const calls = [_]ToolCall{
        .{ .id = "call-1", .name = "noop", .arguments_json = "[]" },
    };
    const results = try executeToolCalls(std.testing.allocator, &registered, &calls, .{ .strict_validation = true });
    defer {
        for (results) |result| {
            if (result.failed) std.testing.allocator.free(@constCast(result.output));
        }
        std.testing.allocator.free(results);
    }
    try std.testing.expect(results[0].failed);
    try std.testing.expectEqualStrings("{\"error\":\"InvalidToolArguments\"}", results[0].output);
}
