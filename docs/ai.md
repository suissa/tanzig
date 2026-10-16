# Tanzig AI

Tanzig includes a Zig-native implementation of the core concepts behind TanStack AI. The public API is exposed through `zx.ai` and is designed around the same separation used by TanStack AI: a provider-agnostic chat activity, a provider adapter, a stream of typed chunks, and a persistent WebSocket transport.

The current OpenAI adapter supports both the OpenAI Responses API and the Chat Completions API. TanStack AI's current `openaiText()` uses `/v1/responses`, while its `openaiChatCompletions()` adapter uses `/v1/chat/completions`.

## Server

```zig
const zx = @import("zx");

const openai = zx.ai.openaiText("gpt-5.2", std.posix.getenv("OPENAI_API_KEY") orelse "");

fn chatSocket(
    socket: zx.Socket,
    message: []const u8,
    message_type: zx.SocketMessageType,
    _: ?[]const u8,
    allocator: std.mem.Allocator,
    _: std.mem.Allocator,
    _: std.Io,
) !void {
    if (message_type != .text) return error.InvalidRequest;
    try zx.ai.websocket.handle(.{ .adapter = openai }, socket, message, allocator);
}
```

Register `chatSocket` as the `socket` handler of a route. Tanzig's server router exposes `SocketHandler`, `SocketOpenHandler`, and `SocketCloseHandler` specifically for WebSocket routes.

The incoming frame can be either a single `message` or a conversation in `messages`:

```json
{
  "messages": [
    {"role": "user", "content": "Hello"}
  ],
  "threadId": "thread-1",
  "runId": "run-1"
}
```

Every response is sent as a JSON stream chunk. The lifecycle is:

`RUN_STARTED → TEXT_MESSAGE_START → TEXT_MESSAGE_CONTENT* → TEXT_MESSAGE_END → RUN_FINISHED`

Validation failures and provider failures are represented by `RUN_ERROR`.

## WebChat

```zig
const zx = @import("zx");

pub fn Page(ctx: zx.PageContext) zx.Component {
    return (
        <main @allocator={ctx.arena}>
            <zx.ai.WebChat endpoint="/api/chat-ws" title="Assistant" />
        </main>
    );
}
```

`WebChat` creates a complete browser chat UI, keeps one WebSocket connection for the conversation, prevents normal form navigation, sends the full conversation as JSON, renders user messages immediately, and appends assistant deltas as they arrive. The browser connection follows the same one-socket/many-turn model as TanStack AI's WebSocket transport.

## Provider API

```zig
const adapter = zx.ai.openaiText("gpt-5.2", api_key);
const legacy = zx.ai.openaiChatCompletions("gpt-5.2", api_key);
```

`openaiText` targets Responses. `openaiChatCompletions` targets Chat Completions. This mirrors the two OpenAI adapter choices exposed by `@tanstack/ai-openai`.

## Scope

This first implementation keeps the public surface small and framework-native: text chat, validation, streaming lifecycle events, OpenAI adapters, WebSocket transport, and a ready-to-use WebChat component. Tool calling, structured output, multimodal content, durable/resumable streams, and other TanStack AI activities can be layered onto the same adapter/chunk interfaces without coupling the UI to the provider.
