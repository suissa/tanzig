const zx = @import("../root.zig");

pub const Props = struct {
    endpoint: []const u8 = "/api/chat-ws",
    id: []const u8 = "tanzig-ai-webchat",
    placeholder: []const u8 = "Message...",
    title: []const u8 = "AI Chat",
};

/// Complete browser WebChat component for a Tanzig WebSocket AI endpoint.
pub fn WebChat(allocator: zx.Allocator, props: Props) zx.Component {
    return (
        <section @allocator={allocator} id={props.id} data-tanzig-ai-chat="true" data-endpoint={props.endpoint}>
            <style>{styles}</style>
            <div class="tz-ai-shell">
                <header class="tz-ai-header">
                    <strong>{props.title}</strong>
                    <span data-status="offline">offline</span>
                </header>
                <div class="tz-ai-messages" data-messages="true" role="log" aria-live="polite"></div>
                <form class="tz-ai-form" data-form="true">
                    <input data-input="true" name="message" autocomplete="off" placeholder={props.placeholder} aria-label="Message" />
                    <button type="submit">Send</button>
                </form>
            </div>
            <script>{script}</script>
        </section>
    );
}

const styles =
    \.tz-ai-shell { display:grid; grid-template-rows:auto 1fr auto; min-height:520px; max-width:760px; margin:0 auto; border:1px solid color-mix(in srgb, currentColor 18%, transparent); border-radius:18px; overflow:hidden; background:color-mix(in srgb, Canvas 96%, currentColor 4%); color:CanvasText; font:14px/1.5 system-ui,sans-serif; }
    \.tz-ai-header { display:flex; align-items:center; justify-content:space-between; padding:16px 18px; border-bottom:1px solid color-mix(in srgb, currentColor 12%, transparent); }
    \.tz-ai-header span { font-size:12px; opacity:.65; }
    \.tz-ai-messages { display:flex; flex-direction:column; gap:12px; padding:18px; overflow:auto; }
    \.tz-ai-msg { max-width:82%; padding:11px 14px; border-radius:14px; white-space:pre-wrap; overflow-wrap:anywhere; }
    \.tz-ai-user { align-self:flex-end; background:color-mix(in srgb, Highlight 18%, Canvas); }
    \.tz-ai-assistant { align-self:flex-start; background:color-mix(in srgb, currentColor 8%, Canvas); }
    \.tz-ai-form { display:flex; gap:8px; padding:14px; border-top:1px solid color-mix(in srgb, currentColor 12%, transparent); }
    \.tz-ai-form input { min-width:0; flex:1; padding:12px 14px; border:1px solid color-mix(in srgb, currentColor 18%, transparent); border-radius:12px; background:Canvas; color:CanvasText; outline:none; }
    \.tz-ai-form button { padding:0 18px; border:0; border-radius:12px; background:Highlight; color:HighlightText; cursor:pointer; }
    \.tz-ai-form button:disabled { opacity:.5; cursor:wait; }
;

const script =
    \(() => {
    \  const root = document.currentScript?.parentElement;
    \  if (!root) return;
    \  const endpoint = root.dataset.endpoint || '/api/chat-ws';
    \  const messagesEl = root.querySelector('[data-messages]');
    \  const form = root.querySelector('[data-form]');
    \  const input = root.querySelector('[data-input]');
    \  const button = form?.querySelector('button');
    \  const status = root.querySelector('[data-status]');
    \  let socket = null;
    \  let history = [];
    \  let assistantEl = null;
    \  let runId = null;
    \  const setStatus = (value) => { if (status) { status.textContent = value; status.dataset.status = value; } };
    \  const wsUrl = () => {
    \    if (endpoint.startsWith('ws://') || endpoint.startsWith('wss://')) return endpoint;
    \    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    \    return protocol + '//' + location.host + endpoint;
    \  };
    \  const addMessage = (role, text) => {
    \    const el = document.createElement('div');
    \    el.className = 'tz-ai-msg ' + (role === 'user' ? 'tz-ai-user' : 'tz-ai-assistant');
    \    el.textContent = text;
    \    messagesEl.appendChild(el);
    \    messagesEl.scrollTop = messagesEl.scrollHeight;
    \  };
    \  const connect = () => {
    \    if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
    \    socket = new WebSocket(wsUrl());
    \    socket.onopen = () => setStatus('online');
    \    socket.onerror = () => setStatus('error');
    \    socket.onclose = () => { setStatus('offline'); socket = null; };
    \    socket.onmessage = (event) => {
    \      let chunk;
    \      try { chunk = JSON.parse(event.data); } catch { return; }
    \      switch (chunk.type) {
    \        case 'RUN_STARTED': runId = chunk.runId || runId; assistantEl = null; break;
    \        case 'TEXT_MESSAGE_START':
    \          assistantEl = document.createElement('div');
    \          assistantEl.className = 'tz-ai-msg tz-ai-assistant';
    \          assistantEl.dataset.messageId = chunk.messageId || '';
    \          messagesEl.appendChild(assistantEl);
    \          break;
    \        case 'TEXT_MESSAGE_CONTENT':
    \          if (!assistantEl) { assistantEl = document.createElement('div'); assistantEl.className = 'tz-ai-msg tz-ai-assistant'; messagesEl.appendChild(assistantEl); }
    \          assistantEl.textContent += chunk.delta || '';
    \          messagesEl.scrollTop = messagesEl.scrollHeight;
    \          break;
    \        case 'TEXT_MESSAGE_END':
    \          if (assistantEl) history.push({ role: 'assistant', content: assistantEl.textContent });
    \          assistantEl = null;
    \          break;
    \        case 'RUN_FINISHED':
    \          if (button) button.disabled = false;
    \          if (input) input.disabled = false;
    \          break;
    \        case 'RUN_ERROR':
    \          if (assistantEl) assistantEl.textContent += '\\n\\nError: ' + (chunk.message || 'unknown error');
    \          else addMessage('assistant', 'Error: ' + (chunk.message || 'unknown error'));
    \          if (button) button.disabled = false;
    \          if (input) input.disabled = false;
    \          break;
    \      }
    \    };
    \  };
    \  form?.addEventListener('submit', (event) => {
    \    event.preventDefault();
    \    const text = input?.value.trim();
    \    if (!text) return;
    \    connect();
    \    const send = () => {
    \      const user = { role: 'user', content: text };
    \      history.push(user);
    \      addMessage('user', text);
    \      if (input) { input.value = ''; input.disabled = true; }
    \      if (button) button.disabled = true;
    \      runId = crypto.randomUUID();
    \      socket.send(JSON.stringify({ messages: history, runId }));
    \    };
    \    if (socket?.readyState === WebSocket.OPEN) send();
    \    else socket?.addEventListener('open', send, { once: true });
    \  });
    \  connect();
    \})();
;
