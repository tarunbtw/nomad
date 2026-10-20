---
name: nomad-browser
description: Direct control, token-optimized perception, and vision-grounded automation of the Nomad macOS browser engine. Use whenever interacting with Nomad, navigating web pages, inspecting DOM nodes, or automating browser tasks.
---

# Nomad Browser Agent Skill

Nomad is an ultra-lightweight, native macOS WebKit browser engine featuring an embedded local agent server on `127.0.0.1:9222`, token-optimized semantic perception, and an in-app Dev Drawer (`⌘⌥I`).

## Key Principles & Token Efficiency

> [!IMPORTANT]
> **Never request raw page HTML (`outerHTML`).**
> Raw HTML on modern websites consumes between 50,000 and 150,000 tokens per page, rapidly exhausting context windows and introducing hallucination.
> **Always use `nomad_snapshot`** which yields a curated semantic tree costing ~400–2,000 tokens for 100 elements (~15–20 tokens/element; recommend `limit: 40-50` for ~600–900 tokens).

## Available Agent Tools

| Tool | Purpose | Token Cost |
| :--- | :--- | :--- |
| `nomad_status` | Check engine status, open tabs, active page, and supported capabilities | ~50 tokens |
| `nomad_tabs` | List all open tabs (id, title, url, active status) | ~100 tokens |
| `nomad_new_tab` | Open a new tab (optional `url`, `isIncognito`, `select`) | ~50 tokens |
| `nomad_switch_tab` | Switch focused active tab by `id` | ~30 tokens |
| `nomad_close_tab` | Close tab by `id` | ~30 tokens |
| `nomad_navigate` | Navigate active tab to URL, or go back, forward, reload (`action: 'back'|'forward'|'reload'|'url'`, optional `allowLocalFiles: true` for `file://` URLs) | ~50 tokens |
| `nomad_wait` | Wait for DOM stability (`mode: 'stability'`), CSS selector, URL (`mode: 'url'`), network idle (`mode: 'networkidle'`), navigation, or timeout | ~40 tokens |
| `nomad_cookies` | Inspect, inject, or clear session cookies for authentication and state (`action: 'get'|'set'|'clear'`, optional `allDomains: true`) | ~80 tokens |
| `nomad_snapshot` | **Primary perception:** Dense semantic markdown of interactive & text elements (`li`, `p`, `td`, `th`), deterministic IDs, redaction, pagination, and JSON mode (`mode: 'text' \| 'json'`) | ~400–2,000 tokens |
| `nomad_action` | Atomic interactions (`click`, `hover`, `type`, `clear`, `press`, `selectOption`, `scroll`, `drag`, `highlight`, `upload`) with automatic self-healing retry on stale refs | ~40 tokens |
| `nomad_upload` | Programmatic file upload to `<input type="file">`, label, or dropzone without modal system dialogs (`paths: string[]`) | ~40 tokens |
| `nomad_screenshot` | GPU snapshot; set `labeled: true` for vision badges, or `elementId` / `clip` for cropped region capture | Base64 image |
| `nomad_evaluate` | Run expression-oriented JavaScript in page or isolated context (`world: 'page' | 'isolated'`); returns value or descriptive error | Minimal |
| `nomad_dialog` | Inspect or configure JavaScript dialog handling (`policy: 'accept' \| 'dismiss'`, optional prompt response text) | ~40 tokens |
| `nomad_console` | Inspect recent page console logs (`log`, `warn`, `error`) or clear log buffer | ~100 tokens |
| `nomad_network` | Inspect recent HTTP requests (fetch/XHR), status codes, latencies, and errors | ~150 tokens |

---

## Standard Workflow

### 1. Navigation & State Verification
```json
// Navigate to page (pass allowLocalFiles: true for file:// URLs)
nomad_navigate({ "url": "https://example.com" })

// Check status or verify active tab
nomad_status({})
```

### 2. Dense Semantic Perception (~400–2,000 tokens)
Call `nomad_snapshot`. It returns a distilled tree with deterministic `[eN]` refs, text elements (`li`, `p`, `td`) for outcome verification, `(offscreen)` flags, and automatic redaction of sensitive credentials/payment data:
```markdown
=== Nomad Semantic Perception ===
Tokens: ~380
URL: https://example.com/todos
Title: Todo App

[e1] <h1 "Tasks">
[e2] <input id="new-todo" placeholder="What needs to be done?" type="text">
[e3] <button id="add">Add</button>
[e4] <li "Buy milk">
[e5] <a href="/login">Sign In</a> (offscreen)
```
Default mode returns the token-efficient semantic perception markdown (~400–2,000 tokens for 100 elements; recommend `limit: 40-50` for ~400–800 tokens). To receive the full JSON AST array of elements, pass `mode: 'json'`:
```json
nomad_snapshot({ "limit": 40, "offset": 0, "viewportOnly": true, "includeText": true })
// Or full JSON AST element array:
nomad_snapshot({ "mode": "json" })
```

> [!NOTE]
> **URL Display in Header:** Snapshot headers echo the current page URL for context grounding. `data:` URLs are collapsed to `data:<mime>;length=N` and long URLs are truncated to prevent context pollution.

### 3. Precision Action Dispatch
Interact with elements directly by reference:
```json
// Type into input
nomad_action({
  "type": "type",
  "elementId": "e1",
  "text": "MacBook Pro"
})

// Click button
nomad_action({
  "type": "click",
  "elementId": "e2"
})
```

Supported action types:
- `click`: Triggers synthetic PointerDown, PointerUp, and Click events at the element's center. Occlusion-aware: if an overlay or modal backdrop covers the element, the click hits the topmost covering element unless `force: true` is passed.
- `hover`: Dispatches pointerover/pointerenter/mousemove sequence to open dropdown menus or tooltips.
- `type`: Focuses element and sets value via prototype setter (React 16+ and contentEditable compatible). Dispatches `input` events per keystroke. If text is empty/omitted and `submit: true` is passed, existing field content is preserved. To commit changes, pass `submit: true` (presses Enter), `blur: true`, or `change: true`.
- `clear`: Wipes input/textarea/contentEditable value and triggers change events.
- `press`: Simulates key press or modifier chord (e.g. `key: "Enter"`, `key: "Meta+A"`, `key: "Escape"`). Validates key names against standard named keys (`Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `ArrowUp/Down/Left/Right`, `Space`, function keys `F1`–`F12`, and modifier chords); rejects unknown key names.
- `selectOption`: Chooses native HTML `<select>` dropdown option by `optionValue` or `optionText`. For custom ARIA/div dropdowns (e.g. Radix, HeadlessUI, React-Select), click the dropdown trigger element, wait/snapshot, and click the option element.
- `scroll`: Scrolls the viewport by `scrollDeltaY` pixels (e.g. `300` to scroll down, `-300` to scroll up) or `scrollDeltaX`.
- `drag`: Dispatches standard HTML5 drag-and-drop sequence (`dragstart`, `dragover`, `drop`, `dragend`) to destination (`toX`, `toY`).
- `highlight`: Briefly flashes a high-contrast visual outline over the element for visual confirmation.
- `upload`: Programmatically injects local files into `<input type="file">`, associated `<label>`, or dropzone containers without triggering blocking macOS `NSOpenPanel` sheets (`paths: string[]`). Automatically validates file existence on disk before dispatch.

> [!TIP]
> **Ref Self-Healing & Stale Ref Protection:**
> When asynchronous DOM shifts alter element indices between calls, Nomad automatically executes semantic signature matching (by ID, testId, name, or aria-label) to find the intended control. If an element reference is no longer in the DOM, was snapshotted as a non-editable tag, or resolves to an incompatible node (e.g. attempting to type into a shifted image, link, or checkbox), Nomad strictly returns `{ "success": false, "staleRef": true, "code": "STALE_REF" }` prompting you to call `nomad_snapshot` for fresh element refs instead of silently executing actions on arbitrary elements.

> [!NOTE]
> **JavaScript Evaluation (`nomad_evaluate`):**
> Evaluates expression-oriented JavaScript in page context. To run multi-statement scripts or declare variables, wrap the code in an IIFE: `(() => { const x = 1; return x + 1; })()`.
> Pass `world: "isolated"` to execute in an isolated WebKit content world (`.defaultClient`) that bypasses page-level CSP or script interference.

### 4. Vision Grounding (Multimodal Verification)
When visual spatial layout is required, capture a vision-grounded screenshot:
```json
nomad_screenshot({ "labeled": true })
```
This renders numbered visual badges matching the snapshot references (`[1]`, `[2]`, ...) directly on the WebKit GPU frame before capturing the PNG, giving vision models exact pixel grounding.

> [!TIP]
> **Animated SPAs & Entrance Transitions (Framer, WebGL, Canvas):**
> Modern landing pages (such as Framer or WebGL showcases) frequently utilize initial entrance fade-in animations (`opacity: 0 -> 1` over 500–1000ms). When observing such pages, call `nomad_wait({ mode: "timeout", durationMs: 1200 })` or wait for stability before capturing the reference screenshot, and visually inspect the frame before proceeding.
>
> **Choosing the Right Wait Mode:**
> - `mode: "stability"`: Waits for ongoing DOM mutation bursts to quiet down (great after clicks, modal opens, or accordion transitions). It settles once active churn stops; it does not wait for delayed future timers.
> - `mode: "selector"`: Best for async UI renders or API fetches — returns immediately once the target node mounts in the DOM. Automatically pierces open Shadow DOM roots and nested same-origin frames.
> - `mode: "networkidle"`: Best for data-heavy SPAs that perform background fetch/XHR queries before rendering content. Waits until in-flight requests settle for 500ms (for pages with recurring polling intervals like `setInterval(fetch, 200ms)`, use `stability` or `selector` instead).
> - `mode: "navigation"` or `mode: "url"`: Best when awaiting full-page redirects or SPA history transitions. Matches against both raw and percent-decoded URLs (e.g. `Special:Search` matches `Special%3ASearch`). When called without a URL pattern, waits for active navigation loading to complete or URL to change, preventing premature returns.

---

## Developer Drawer (In-App DevX)

- **Keyboard Shortcut:** `⌘⌥I` toggles the minimalist Dev Drawer at the bottom of the active web tab.
- **Inspect Tab:** Crosshair picker (`Pick Element`) highlights hovered nodes and displays Tag, ID, Classes, Bounding Size, Inner Text, and Agent Reference (`[eN]`).
- **Console Tab:** Streams live `console.log`, `console.warn`, and `console.error` messages from the active page, with a 1-line JS REPL bar.
- **Agent Tab:** Displays live status of the local server (`127.0.0.1:9222`), request counters, live Semantic Tree capture, and Labeled Screenshot preview.
- **Safari Web Inspector Fallback:** `webView.isInspectable = true` is enabled by default. Right-click any element and select "Inspect Element" to open Safari Web Inspector.

---

## Authentication & Security

Nomad's embedded local server (`127.0.0.1:9222`) is protected by bearer token authentication:
- **Token Location:** Automatically generated on launch at `~/.nomad/agent-token` with strict POSIX `0600` permissions (only accessible to the current user).
- **Native MCP Auto-Auth:** When launched via `nomad --mcp`, the native Swift MCP server automatically reads `~/.nomad/agent-token` (or the `NOMAD_TOKEN` environment variable) and authenticates all tool calls to the running browser.
- **Direct HTTP Calls:** If communicating with the server directly (e.g. via `curl` or custom scripts), pass the token in the `Authorization` or `X-Nomad-Token` header:
  ```bash
  TOKEN=$(cat ~/.nomad/agent-token)
  curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9222/snapshot
  ```
- **Health & Liveness Probes:** `GET /status` returns `{ "nomad": "active", "version": "1.0", "port": 9222, "authRequired": true }` unauthenticated. When authenticated with your Bearer token, it returns full engine status: `tabsCount`, `tabCount`, `activeTabId`, `activeURL`, `activeUrl`, `activeTitle`, `capabilities`, and `lastDialog`.

---

## Direct HTTP REST API Reference (`127.0.0.1:9222`)

For environments driving Nomad directly without MCP (e.g. `curl`, Python, Node.js scripts), authenticate with `Authorization: Bearer <token>` or `X-Nomad-Token: <token>`.

| Method | Endpoint | Description / Parameters |
| :--- | :--- | :--- |
| `GET` | `/status` | Engine health, capabilities, tab counts (`tabsCount`, `tabCount`), active URL (`activeURL`, `activeUrl`) |
| `GET` | `/tabs` | List open tabs (`id`, `title`, `url`, `active`, `isActive`, `isLoading`, `isIncognito`) |
| `POST` | `/tabs/new` | Body: `{ "url"?: string, "select"?: bool, "isIncognito"?: bool }` |
| `POST` | `/tabs/switch` | Body: `{ "id": string }` |
| `POST` | `/tabs/close` | Body: `{ "id": string }` |
| `POST` | `/navigate` | Body: `{ "url"?: string, "action"?: "url"|"back"|"forward"|"reload", "allowLocalFiles"?: bool }` (for `file://` URLs, pass `allowLocalFiles: true`; concurrent navigations automatically cancel superseded loads) |
| `POST` | `/navigate/back` | Navigate back in browser history |
| `POST` | `/navigate/forward`| Navigate forward in browser history |
| `POST` | `/navigate/reload` | Reload active page |
| `GET` | `/snapshot` | Query: `limit`, `offset`, `viewportOnly=true`, `includeText=true`, `mode=text`, `tabId` |
| `POST` | `/action` | Body: `{ "type": "click"|"hover"|"type"|"clear"|"press"|"selectOption"|"scroll"|"drag"|"highlight"|"upload"` (alias: `action`), `"elementId"?: string`, `"selector"?: string`, `"paths"?: string[]`, ... } |
| `POST` | `/upload` | Body: `{ "elementId": string, "paths": string[], "tabId"?: string }` (programmatic file upload without modal GUI sheets) |
| `POST` | `/wait` | Body: `{ "mode": "stability"|"selector"|"url"|"timeout"|"networkidle"|"navigation", "selector"?: string, "urlPattern"?: string` (supports regex or plain substring), `"quietMs"?: int, "timeoutMs"?: int }` |
| `GET` | `/cookies` | Query: `domain` (filter by target domain), `allDomains=true`, `tabId` |
| `POST` | `/cookies` | Body: `{ "action": "set"|"get"|"clear", "domain"?: string, "name"?: string, "value"?: string, "cookies"?: [...], "allDomains"?: bool }` |
| `DELETE` | `/cookies` | Query / Body: `domain` (clears cookies for domain), `allDomains=true` (clears all profile cookies) |
| `GET` / `POST` | `/screenshot` | Query / Body: `labeled=true`, `elementId=eN`, `clip=x,y,w,h` |
| `POST` | `/evaluate` | Body: `{ "script": string }` (alias: `expression`), `world`: `"page"` \| `"isolated"` (returns structured error with `code: "SYNTAX_ERROR"|"EVAL_CSP"` on failure) |
| `POST` | `/dialog` | Body: `{ "policy": "accept"|"dismiss", "response": string }` (alias: `promptResponse`) |
| `GET` | `/console` | Query: `level=all|log|warn|error`, `clear=true`, `tabId` |
| `GET` | `/network` | Query: `statusFilter=all|errors|success`, `clear=true`, `tabId` |

> [!CAUTION]
> **Profile Cookies & State Isolation:**
> Nomad runs against your live profile sessions. Passing `allDomains: true` to `/cookies` inspects or clears cookies across all domains in the profile. For isolated automated testing without affecting personal logins, open tabs with `"isIncognito": true`.

---

## MCP Configuration for Agent Runtimes

Nomad includes a 100% native Swift Model Context Protocol (MCP) server directly inside the app bundle. It communicates over stdio using JSON-RPC 2.0 with zero external dependencies (no Node.js or npm required).

### Claude Code (`~/.claude/desktop_config.json` or project config)
```json
{
  "mcpServers": {
    "nomad": {
      "command": "/Applications/Nomad.app/Contents/MacOS/nomad",
      "args": ["--mcp"]
    }
  }
}
```

### Cursor / Antigravity (`mcp_config.json`)
```json
{
  "mcpServers": {
    "nomad-browser": {
      "command": "/Applications/Nomad.app/Contents/MacOS/nomad",
      "args": ["--mcp"]
    }
  }
}
```

> [!TIP]
> If you have symlinked Nomad to your PATH (`sudo ln -s /Applications/Nomad.app/Contents/MacOS/nomad /usr/local/bin/nomad`), you can simply specify `"command": "nomad"`.
