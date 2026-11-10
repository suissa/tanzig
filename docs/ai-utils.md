# Tanzig AI utilities

Tanzig provides Zig-native primitives inspired by `@cloudflare/ai-utils` without coupling the framework to Cloudflare Workers or a single inference provider.

## Current API

```zig
const ai = @import("ziex").ai;

const Tool = ai.Tool;
const defineTool = ai.tool;
const selectTools = ai.autoTrimTools;
const validateArgs = ai.validateToolArguments;
const executeCalls = ai.executeToolCalls;
const runTools = ai.runWithTools;
```

A tool declares a stable name, description, JSON parameter schema, and an execution callback:

```zig
fn getWeather(allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    _ = allocator;
    _ = arguments_json;
    return "{\\"condition\\":\\"sunny\\"}";
}

const weather = ai.tool(.{
    .name = "get-weather",
    .description = "Gets current weather for a city",
    .parameters_json = "{\\"type\\":\\"object\\",\\"properties\\":{\\"city\\":{\\"type\\":\\"string\\"}},\\"required\\":[\\"city\\"]}",
    .function = getWeather,
});
```

### Tool primitives

- `tool(definition)`: typed, allocation-free tool declaration helper.
- `autoTrimTools(allocator, tools, prompt, options)`: deterministic lexical relevance selection; returns an allocated slice that the caller must free.
- `validateToolArguments(allocator, json)`: parses JSON and requires the top-level value to be an object.
- `executeToolCalls(allocator, registered_tools, calls, options)`: executes a complete batch in order, preserves call IDs, and returns one result per call. Unknown tools, strict argument failures, and callback errors become individual error results rather than aborting the batch.
- `runWithTools(allocator, tools, invoker, options)`: repeatedly invokes a provider-neutral model callback, executes returned tool batches, and supplies each batch's results to the next model turn. Returns when the model produces text without tool calls; enforces `max_recursive_tool_runs`.
- `ModelInvoker`: callback plus opaque context. The application owns provider conversation state and must append the supplied tool results to that state before returning the next model response.
- `RunOptions`: controls strict argument checks and the maximum number of tool rounds.

### Minimal orchestration shape

The invoker receives the registered tools and the previous tool-result batch. It is responsible for calling the selected inference provider with its conversation state and returning either another batch of `ToolCall` values or final text. This keeps credentials, provider-specific tool-call encoding, and conversation storage outside the utility module.

## Compatibility notes

This is a native Zig compatibility layer, not a binary-compatible port of the TypeScript package. `autoTrimTools` currently uses deterministic lexical relevance rather than an additional model call. Argument validation currently checks JSON syntax and the top-level object shape; it does not yet implement complete JSON Schema validation.

The OpenAI adapter currently streams text responses; it does not yet decode native provider tool-call events into `ModelReply`. Applications can implement `ModelInvoker` against a provider that exposes tool calls. OpenAPI JSON/YAML conversion and HTTP request overrides are also not implemented yet. The module deliberately does not claim Workers-only embedded function calling works over arbitrary REST APIs.

## Tests

Run `zig test src/ai/utils.zig` and `zig test src/ai/tool_runner.zig` with the repository's Zig 0.17 toolchain. Successful tool callback output is borrowed by the result; the callback defines its lifetime. Error result payloads are allocated by the supplied allocator and freed by the runner after the next invocation has consumed them.
