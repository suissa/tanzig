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
