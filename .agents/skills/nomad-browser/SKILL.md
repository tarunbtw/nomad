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
> **Always use `nomad_snapshot`** which yields a dense, curated semantic tree costing only ~250–400 tokens per page.

## Available Agent Tools

| Tool | Purpose | Token Cost |
| :--- | :--- | :--- |
| `nomad_status` | Check if Nomad is active, get open tab count, active URL and title | ~50 tokens |
| `nomad_tabs` | List all open tabs (id, title, url, active status) | ~100 tokens |
| `nomad_new_tab` | Open a new tab (optional `url`, `isIncognito`, `select`) | ~50 tokens |
| `nomad_switch_tab` | Switch focused active tab by `id` | ~30 tokens |
| `nomad_close_tab` | Close tab by `id` | ~30 tokens |
| `nomad_navigate` | Navigate active tab to URL, or go back, forward, reload (`action: 'back'|'forward'|'reload'|'url'`) | ~50 tokens |
| `nomad_wait` | Wait for DOM mutation stability, a specific CSS selector, or timeout (essential for SPAs) | ~40 tokens |
| `nomad_cookies` | Inspect, inject, or clear session cookies for authentication and state | ~80 tokens |
| `nomad_snapshot` | **Primary perception:** Dense semantic markdown of visible interactive elements (including Shadow DOM, occlusion checks, and accessible states) | ~300 tokens |
| `nomad_action` | Dispatch atomic actions: `click`, `hover`, `type` (React-compatible), `clear`, `press` (key chords), `selectOption`, `scroll`, `highlight` | ~40 tokens |
| `nomad_screenshot` | GPU snapshot; set `labeled: true` for vision-grounded element numbered badges | Base64 image |
| `nomad_evaluate` | Run arbitrary JavaScript in page context and return result | Minimal |

---

## Standard Workflow

### 1. Navigation & State Verification
```json
// Navigate to page
nomad_navigate({ "url": "https://example.com" })

// Check status or verify active tab
nomad_status({})
```

### 2. Dense Semantic Perception (~300 tokens)
Call `nomad_snapshot`. It returns a distilled markdown tree:
```markdown
=== Nomad Semantic Perception ===
Tokens: ~280
URL: https://example.com
Title: Example Domain

[e1] <input id="search" placeholder="Search..." type="text">
[e2] <button id="submit">Search</button>
[e3] <a href="/docs">Documentation</a>
[e4] <a href="/login">Sign In</a>
```

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
- `click`: Triggers synthetic PointerDown, PointerUp, and Click events at the element's bounding center.
- `hover`: Dispatches pointerover/pointerenter/mousemove sequence to open dropdown menus or tooltips.
- `type`: Clears/focuses element and sets value via prototype setter (React 16+ compatible) with native input/change dispatch.
- `clear`: Wipes input/textarea value and triggers change events.
- `press`: Simulates key press or modifier chord (e.g. `text: "Enter"`, `text: "Meta+A"`, `text: "Shift+Tab"`).
- `selectOption`: Chooses dropdown `<option>` by `optionValue` or `optionText`.
- `scroll`: Scrolls the viewport by `scrollDeltaY` pixels (e.g. `300` to scroll down, `-300` to scroll up) or `scrollDeltaX`.
- `highlight`: Briefly flashes an orange highlight box over the element for visual confirmation.

### 4. Vision Grounding (Multimodal Verification)
When visual spatial layout is required, capture a vision-grounded screenshot:
```json
nomad_screenshot({ "labeled": true })
```
This renders numbered visual badges matching the snapshot references (`[1]`, `[2]`, ...) directly on the WebKit GPU frame before capturing the PNG, giving vision models exact pixel grounding.

> [!TIP]
> **Animated SPAs & Entrance Transitions (Framer, WebGL, Canvas):**
> Modern landing pages (such as Framer or WebGL showcases) frequently utilize initial entrance fade-in animations (`opacity: 0 -> 1` over 500–1000ms). When observing such pages, call `nomad_wait({ mode: "timeout", durationMs: 1200 })` or wait for stability before capturing the reference screenshot, and visually inspect the frame before proceeding.

---

## Developer Drawer (In-App DevX)

- **Keyboard Shortcut:** `⌘⌥I` toggles the minimalist Dev Drawer at the bottom of the active web tab.
- **Inspect Tab:** Crosshair picker (`Pick Element`) highlights hovered nodes and displays Tag, ID, Classes, Bounding Size, Inner Text, and Agent Reference (`[eN]`).
- **Console Tab:** Streams live `console.log`, `console.warn`, and `console.error` messages from the active page, with a 1-line JS REPL bar.
- **Agent Tab:** Displays live status of the local server (`127.0.0.1:9222`), request counters, live Semantic Tree capture, and Labeled Screenshot preview.
- **Safari Web Inspector Fallback:** `webView.isInspectable = true` is enabled by default. Right-click any element and select "Inspect Element" to open Safari Web Inspector.

---

## MCP Configuration for Agent Runtimes

### Claude Code (`~/.claude/desktop_config.json` or project config)
```json
{
  "mcpServers": {
    "nomad": {
      "command": "node",
      "args": ["/Users/tarun/projects/nomad/mcp/nomad-mcp.js"]
    }
  }
}
```

### Cursor / Antigravity (`mcp_config.json`)
```json
{
  "mcpServers": {
    "nomad-browser": {
      "command": "node",
      "args": ["/Users/tarun/projects/nomad/mcp/nomad-mcp.js"]
    }
  }
}
```
