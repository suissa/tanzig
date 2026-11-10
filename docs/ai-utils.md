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
```

A tool declares a stable name, description, JSON parameter schema, and an execution callback:

```zig
fn getWeather(allocator: std.mem.Allocator, arguments_json: []const u8) ![]u8 {
    _ = allocator;
    _ = arguments_json;
    return "{\"condition\":\"sunny\"}";
}

const weather = ai.tool(.{
    .name = "get-weather",
    .description = "Gets current weather for a city",
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}",
    .function = getWeather,
});
```

### Tool primitives

- `tool(definition)`: typed, allocation-free tool declaration helper.
- `autoTrimTools(allocator, tools, prompt, options)`: deterministic lexical relevance selection; returns an allocated slice that the caller must free.
- `validateToolArguments(allocator, json)`: parses JSON and requires the top-level value to be an object.\n- `executeToolCalls(allocator, registered_tools, calls, options)`: executes a complete batch in order, preserves call IDs, and returns one result per call. Unknown tools, strict argument failures, and callback errors become individual error results rather than aborting the batch.
- `RunOptions`: exposes the configuration shape for strict validation, recursive tool-run limits, final streaming, and verbose diagnostics.

## Compatibility notes

This is a native Zig compatibility layer, not a binary-compatible port of the TypeScript package. `autoTrimTools` currently uses deterministic lexical relevance rather than an additional model call. Argument validation currently checks JSON syntax and the top-level object shape; it does not yet implement complete JSON Schema validation.

The full Cloudflare package also includes `runWithTools` orchestration (model invocation, multi-tool execution, recursive calls and streaming final answers) and `createToolsFromOpenAPISpec` (OpenAPI JSON/YAML conversion with request overrides). Those integrations require provider-neutral inference/tool-call interfaces and HTTP/OpenAPI schema handling; they are not represented as complete in this initial utility layer. The module deliberately does not claim Workers-only embedded function calling works over arbitrary REST APIs.

## Tests

The module includes unit tests for tool declaration, JSON-object argument validation, relevance-based tool selection, multi-call execution, unknown-tool handling, and strict-mode rejection. Run `zig test src/ai/utils.zig` with the repository's Zig 0.17 toolchain. Successful tool callback output is borrowed by the result; the callback defines its lifetime. Error result payloads are allocated by the supplied allocator and must be freed by the caller.
