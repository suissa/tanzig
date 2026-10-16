/// TanStack AI-compatible primitives for Tanzig.
///
/// This is a Zig-native implementation of the core concepts used by
/// @tanstack/ai and @tanstack/ai-openai: provider adapters, chat lifecycle,
/// streaming chunks, validation, and a persistent WebSocket transport.
pub const types = @import("ai/types.zig");
pub const chat = @import("ai/chat.zig");
pub const openai = @import("ai/openai.zig");
pub const websocket = @import("ai/websocket.zig");
pub const webchat = @import("ai/webchat.zig");
pub const utils = @import("ai/utils.zig");

pub const Tool = utils.Tool;
pub const ToolRunOptions = utils.RunOptions;
pub const ToolTrimOptions = utils.TrimOptions;
pub const tool = utils.tool;
pub const autoTrimTools = utils.autoTrimTools;
pub const validateToolArguments = utils.validateToolArguments;

pub const Message = types.Message;
pub const Role = types.Role;
pub const ChatRequest = types.ChatRequest;
pub const StreamChunk = types.StreamChunk;
pub const StreamType = types.StreamType;

pub const chatRun = chat.chat;
pub const streamToText = chat.streamToText;

pub const openaiText = openai.openaiText;
pub const openaiChatCompletions = openai.openaiChatCompletions;
pub const OpenAIConfig = openai.Config;
pub const OpenAIAdapter = openai.Adapter;

pub const WebChat = webchat.WebChat;
pub const WebChatProps = webchat.Props;
