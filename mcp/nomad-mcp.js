#!/usr/bin/env node

/**
 * Nomad Browser - Model Context Protocol (MCP) Server
 * Zero-dependency, high-efficiency bridge between AI agents and Nomad's native browser engine.
 *
 * Built with pure Node.js stdlib (no npm dependencies needed).
 * Connects AI agents (Claude Code, Cursor, Antigravity, Gemini) to Nomad via JSON-RPC 2.0 stdio.
 */

const http = require('node:http');
const readline = require('node:readline');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const NOMAD_PORT = parseInt(process.env.NOMAD_AGENT_PORT || '9222', 10);
const HOST = '127.0.0.1';

/**
 * Resolves local bearer token from NOMAD_TOKEN or ~/.nomad/agent-token
 */
function getAgentToken() {
    if (process.env.NOMAD_TOKEN) return process.env.NOMAD_TOKEN.trim();
    try {
        const tokenPath = path.join(os.homedir(), '.nomad', 'agent-token');
        if (fs.existsSync(tokenPath)) {
            return fs.readFileSync(tokenPath, 'utf8').trim();
        }
    } catch (e) {}
    return null;
}

/**
 * Perform an HTTP request to Nomad's local agent server.
 */
function callNomad(method, pathStr, body = null) {
    return new Promise((resolve, reject) => {
        const payload = body ? JSON.stringify(body) : null;
        const token = getAgentToken();
        const waitMs = (body && (body.timeoutMs || body.durationMs)) || 5000;
        const reqTimeout = Math.max(30000, waitMs + 10000);
        const headers = {
            'Content-Type': 'application/json',
            ...(token ? { 'Authorization': `Bearer ${token}` } : {}),
            ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {})
        };
        const options = {
            hostname: HOST,
            port: NOMAD_PORT,
            path: pathStr,
            method: method,
            headers: headers,
            timeout: reqTimeout
        };

        const req = http.request(options, (res) => {
            const chunks = [];
            res.on('data', (chunk) => chunks.push(chunk));
            res.on('end', () => {
                const buffer = Buffer.concat(chunks);
                const contentType = res.headers['content-type'] || '';

                if (contentType.includes('application/json')) {
                    try {
                        resolve(JSON.parse(buffer.toString('utf8')));
                    } catch (e) {
                        resolve(buffer.toString('utf8'));
                    }
                } else if (contentType.includes('image/')) {
                    resolve({ _rawImage: buffer, contentType });
                } else {
                    resolve(buffer.toString('utf8'));
                }
            });
        });

        req.on('timeout', () => {
            req.destroy();
            reject(new Error(`Operation timed out after ${reqTimeout}ms waiting for response from Nomad (${method} ${pathStr}). Nomad is running, but the page operation exceeded the timeout.`));
        });

        req.on('error', (err) => {
            if (err.code === 'ECONNREFUSED') {
                reject(new Error(`Could not connect to Nomad at http://${HOST}:${NOMAD_PORT} (ECONNREFUSED). Nomad browser is not currently running.`));
            } else {
                reject(new Error(`Network error communicating with Nomad: ${err.message}`));
            }
        });

        if (payload) {
            req.write(payload);
        }
        req.end();
    });
}

function formatToolResponse(res, customText = null) {
    const isErr = Boolean(res && typeof res === 'object' && (res.error || res.success === false || (res.code && String(res.code).startsWith('EVAL_'))));
    let text;
    if (isErr) {
        const errVal = res && (res.error || res.message);
        text = typeof res === 'string' ? res : (errVal ? (typeof errVal === 'string' ? errVal : JSON.stringify(errVal)) : JSON.stringify(res, null, 2));
    } else {
        text = customText !== null ? customText : (typeof res === 'string' ? res : JSON.stringify(res, null, 2));
    }
    return {
        content: [{ type: 'text', text }],
        isError: isErr
    };
}

function sanitizeUrlForDisplay(rawUrl) {
    if (!rawUrl || typeof rawUrl !== 'string') return '';
    if (rawUrl.startsWith('data:')) {
        const comma = rawUrl.indexOf(',');
        const mime = comma > 0 ? rawUrl.substring(0, comma) : 'data:text/html';
        return `${mime};length=${rawUrl.length}`;
    }
    if (rawUrl.length > 200) {
        return rawUrl.substring(0, 197) + '...';
    }
    return rawUrl;
}

const TOOLS = [
    {
        name: 'nomad_status',
        description: 'Check if Nomad browser engine is active, get version, tab counts, active page info, and engine capabilities.',
        inputSchema: {
            type: 'object',
            properties: {},
            additionalProperties: false
        }
    },
    {
        name: 'nomad_tabs',
        description: 'List all open tabs in Nomad with their ID, title, URL, active state, and loading status.',
        inputSchema: {
            type: 'object',
            properties: {},
            additionalProperties: false
        }
    },
    {
        name: 'nomad_new_tab',
        description: 'Open a new tab in Nomad. Optionally provide a URL to load immediately.',
        inputSchema: {
            type: 'object',
            properties: {
                url: { type: 'string', description: 'URL to navigate to (optional)' },
                select: { type: 'boolean', description: 'Whether to switch to the new tab immediately (default true)' },
                isIncognito: { type: 'boolean', description: 'Open as incognito / private tab (default false)' }
            },
            additionalProperties: false
        }
    },
    {
        name: 'nomad_switch_tab',
        description: 'Switch the active focused tab in Nomad by tab ID.',
        inputSchema: {
            type: 'object',
            properties: {
                id: { type: 'string', description: 'Tab UUID string' }
            },
            required: ['id'],
            additionalProperties: false
        }
    },
    {
        name: 'nomad_close_tab',
        description: 'Close a tab in Nomad by tab ID.',
        inputSchema: {
            type: 'object',
            properties: {
                id: { type: 'string', description: 'Tab UUID string' }
            },
            required: ['id'],
            additionalProperties: false
        }
    },
    {
        name: 'nomad_navigate',
        description: 'Navigate the active tab to a new URL, or navigate browser history (back, forward, reload).',
        inputSchema: {
            type: 'object',
            properties: {
                url: { type: 'string', description: 'Complete destination URL (e.g. https://github.com)' },
                action: {
                    type: 'string',
                    enum: ['url', 'back', 'forward', 'reload'],
                    description: 'Navigation action. If not specified, defaults to "url".'
                },
                allowLocalFiles: {
                    type: 'boolean',
                    description: 'Explicitly allow navigation to file:// URLs (default false)'
                }
            },
            additionalProperties: false
        }
    },
    {
        name: 'nomad_snapshot',
        description: 'Capture a token-optimized semantic perception tree (typically 300–1,200 tokens depending on page density, vs 50k–100k+ raw HTML). Extracts visible interactive elements, semantic headings (h1-h3), text content (list items, paragraphs, table cells), and images across light and Shadow DOM with assigned IDs ([e1], [e2], ...), bounding coordinates, tag names, roles, accessible text, image src URLs, and occlusion states.',
        inputSchema: {
            type: 'object',
            properties: {
                limit: { type: 'number', description: 'Maximum number of elements to include in semantic tree (default 100)' },
                offset: { type: 'number', description: 'Starting offset for element pagination in dense pages (default 0)' },
                viewportOnly: { type: 'boolean', description: 'When true, only include elements currently inside the visible viewport' },
                includeText: { type: 'boolean', description: 'When true (default), include non-interactive text content (li, p, td, th) for outcome verification' },
                mode: { type: 'string', enum: ['text', 'json'], description: 'Perception output format. "text" returns compact markdown summary; "json" returns raw element array (default: "text")' },
                tabId: { type: 'string', description: 'Optional tab UUID to inspect instead of the active tab' }
            },
            additionalProperties: false
        }
    },
    {
        name: 'nomad_action',
        description: 'Execute an atomic interaction in the active tab (click, hover, type, clear, press key chord, selectOption, scroll, drag, highlight). Best used with elementId from nomad_snapshot (e.g. "e1") or CSS selector fallback. Fully compatible with React controlled components.',
        inputSchema: {
            type: 'object',
            properties: {
                type: {
                    type: 'string',
                    enum: ['click', 'hover', 'type', 'clear', 'press', 'selectOption', 'scroll', 'drag', 'highlight'],
                    description: 'Type of action to execute'
                },
                elementId: {
                    type: 'string',
                    description: 'Target element ID from nomad_snapshot (e.g. "e1", "e2")'
                },
                selector: {
                    type: 'string',
                    description: 'CSS selector fallback if elementId is not used (e.g. ".todo-list li .toggle")'
                },
                text: {
                    type: 'string',
                    description: 'Text to enter (for "type" action) or key name / chord (for "press" action, e.g. "Enter", "Meta+A")'
                },
                optionValue: {
                    type: 'string',
                    description: 'Option value to choose for "selectOption"'
                },
                optionText: {
                    type: 'string',
                    description: 'Option visible text to choose for "selectOption"'
                },
                x: { type: 'number', description: 'Viewport X coordinate fallback' },
                y: { type: 'number', description: 'Viewport Y coordinate fallback' },
                toX: { type: 'number', description: 'Destination X coordinate for drag action' },
                toY: { type: 'number', description: 'Destination Y coordinate for drag action' },
                scrollDeltaY: { type: 'number', description: 'Pixels to scroll down (positive) or up (negative) for "scroll"' },
                scrollDeltaX: { type: 'number', description: 'Pixels to scroll right (positive) or left (negative) for "scroll"' },
                direction: { type: 'string', enum: ['up', 'down', 'left', 'right'], description: 'Scroll direction fallback' },
                amount: { type: 'number', description: 'Pixels to scroll for direction fallback' },
                force: { type: 'boolean', description: 'When true, bypass occlusion check and click target directly even if covered by an overlay' },
                submit: { type: 'boolean', description: 'When true, submit form or press Enter after typing' },
                blur: { type: 'boolean', description: 'When true, blur element after typing to trigger commit' },
                key: { type: 'string', description: 'Key name or chord to press (e.g. "Enter", "Tab", "Escape", "Meta+A")' },
                tabId: { type: 'string', description: 'Optional target tab UUID' }
            },
            required: ['type'],
            additionalProperties: false
        }
    },
    {
        name: 'nomad_wait',
        description: 'Wait for DOM mutation stability, a specific CSS selector, URL pattern, network requests to become idle, navigation to complete, or a timeout before continuing execution.',
        inputSchema: {
            type: 'object',
            properties: {
                mode: {
                    type: 'string',
                    enum: ['stability', 'selector', 'timeout', 'networkidle', 'navigation', 'url'],
                    description: 'Wait mode. Default: stability.'
                },
                selector: {
                    type: 'string',
                    description: 'CSS selector to wait for (if provided, mode defaults to "selector")'
                },
                urlPattern: {
                    type: 'string',
                    description: 'Substring or regex pattern to wait for in active URL (for "navigation" or "url" mode)'
                },
                quietMs: {
                    type: 'number',
                    description: 'Milliseconds of DOM mutation silence required for "stability" (default: 250)'
                },
                timeoutMs: {
                    type: 'number',
                    description: 'Maximum milliseconds to wait before timing out (default: 5000)'
                },
                durationMs: {
                    type: 'number',
                    description: 'Duration in milliseconds for "timeout" mode (default: 1000)'
                },
                idleMs: {
                    type: 'number',
                    description: 'Milliseconds of network silence required for "networkidle" (default: 500)'
                },
                tabId: { type: 'string', description: 'Optional target tab UUID' }
            },
            additionalProperties: false
        }
    },
    {
        name: 'nomad_cookies',
        description: 'Inspect, set, or clear session cookies in the active browser session for authentication and state management.',
        inputSchema: {
            type: 'object',
            properties: {
                action: {
                    type: 'string',
                    enum: ['get', 'set', 'clear'],
                    description: 'Cookie operation (default: get)'
                },
                allDomains: {
                    type: 'boolean',
                    description: 'When true, inspect or clear cookies across all domains, not just the active tab domain'
                },
                name: { type: 'string', description: 'Cookie name (for "set")' },
                value: { type: 'string', description: 'Cookie value (for "set")' },
                domain: { type: 'string', description: 'Domain name for the cookie' },
                path: { type: 'string', description: 'Path for the cookie (default: "/")' },
                isSecure: { type: 'boolean', description: 'Secure cookie flag' },
                isHTTPOnly: { type: 'boolean', description: 'HTTP-only cookie flag' },
                httpOnly: { type: 'boolean', description: 'Alias for isHTTPOnly' },
                expires: { type: 'number', description: 'Unix timestamp in seconds when the cookie expires' }
            },
            additionalProperties: false
        }
    },
    {
        name: 'nomad_screenshot',
        description: 'Capture a GPU screenshot of the active tab. Set labeled=true to overlay numbered element badges [1], [2]. Set elementId (e.g. "e2") or clip to crop to a specific element or region for cheaper vision tokens.',
        inputSchema: {
            type: 'object',
            properties: {
                labeled: {
                    type: 'boolean',
                    description: 'If true, renders vision-grounding element number badges over interactive nodes'
                },
                elementId: {
                    type: 'string',
                    description: 'Optional element ID from nomad_snapshot to crop screenshot to (e.g. "e2")'
                },
                clip: {
                    type: 'object',
                    properties: {
                        x: { type: 'number' },
                        y: { type: 'number' },
                        width: { type: 'number' },
                        height: { type: 'number' }
                    },
                    required: ['x', 'y', 'width', 'height'],
                    description: 'Optional viewport coordinates rectangle to crop screenshot to'
                },
                tabId: { type: 'string', description: 'Optional target tab UUID' }
            },
            additionalProperties: false
        }
    },
    {
        name: 'nomad_evaluate',
        description: 'Evaluate an arbitrary JavaScript expression in the active tab and return the output.',
        inputSchema: {
            type: 'object',
            properties: {
                script: { type: 'string', description: 'JavaScript code to execute' },
                world: {
                    type: 'string',
                    enum: ['page', 'isolated'],
                    description: 'Execution context world (default: page)'
                },
                tabId: { type: 'string', description: 'Optional target tab UUID' }
            },
            required: ['script'],
            additionalProperties: false
        }
    },
    {
        name: 'nomad_dialog',
        description: 'Inspect the last JavaScript dialog (alert/confirm/prompt) or configure automated response policy ("accept" | "dismiss").',
        inputSchema: {
            type: 'object',
            properties: {
                policy: {
                    type: 'string',
                    enum: ['accept', 'dismiss'],
                    description: 'Response policy for window.confirm dialogs (default "accept")'
                },
                response: {
                    type: 'string',
                    description: 'Default text response for window.prompt dialogs'
                }
            },
            additionalProperties: false
        }
    },
    {
        name: 'nomad_console',
        description: 'Inspect recent console log messages (log, warn, error) emitted by the page. Useful for diagnosing frontend issues without blind waits.',
        inputSchema: {
            type: 'object',
            properties: {
                clear: { type: 'boolean', description: 'When true, clears the console log buffer after reading (default: false)' },
                level: { type: 'string', enum: ['all', 'log', 'warn', 'error'], description: 'Filter by log level (default: all)' },
                tabId: { type: 'string', description: 'Optional target tab UUID' }
            },
            additionalProperties: false
        }
    },
    {
        name: 'nomad_network',
        description: 'Inspect recent HTTP network requests (fetch/XHR) executed by the page, including methods, URLs, status codes, latencies, and errors.',
        inputSchema: {
            type: 'object',
            properties: {
                clear: { type: 'boolean', description: 'When true, clears the network log buffer after reading (default: false)' },
                statusFilter: { type: 'string', enum: ['all', 'errors', 'success'], description: 'Filter requests (default: all)' },
                tabId: { type: 'string', description: 'Optional target tab UUID' }
            },
            additionalProperties: false
        }
    }
];

async function handleToolCall(name, args) {
    switch (name) {
        case 'nomad_status': {
            const res = await callNomad('GET', '/status');
            return formatToolResponse(res);
        }
        case 'nomad_tabs': {
            const res = await callNomad('GET', '/tabs');
            return formatToolResponse(res);
        }
        case 'nomad_new_tab': {
            const res = await callNomad('POST', '/tabs/new', args);
            return formatToolResponse(res);
        }
        case 'nomad_switch_tab': {
            const res = await callNomad('POST', '/tabs/switch', args);
            return formatToolResponse(res);
        }
        case 'nomad_close_tab': {
            const res = await callNomad('POST', '/tabs/close', args);
            return formatToolResponse(res);
        }
        case 'nomad_navigate': {
            const res = await callNomad('POST', '/navigate', args);
            return formatToolResponse(res);
        }
        case 'nomad_snapshot': {
            const qs = [];
            if (args && args.limit !== undefined) qs.push(`limit=${encodeURIComponent(args.limit)}`);
            if (args && args.offset !== undefined) qs.push(`offset=${encodeURIComponent(args.offset)}`);
            if (args && args.viewportOnly) qs.push('viewportOnly=true');
            if (args && args.includeText !== undefined) qs.push(`includeText=${encodeURIComponent(args.includeText)}`);
            if (args && args.tabId) qs.push(`tabId=${encodeURIComponent(args.tabId)}`);
            const pathStr = qs.length ? `/snapshot?${qs.join('&')}` : '/snapshot';
            const res = await callNomad('GET', pathStr);
            if (args && args.mode === 'json') {
                return formatToolResponse(res, JSON.stringify(res, null, 2));
            }
            const summary = res.summary || '';
            const tokens = res.tokenEstimate || 0;
            const displayUrl = sanitizeUrlForDisplay(res.url);
            const text = `=== Nomad Semantic Perception ===\nTokens: ~${tokens}\nURL: ${displayUrl}\nTitle: ${res.title || ''}\n\n${summary}`;
            return formatToolResponse(res, text);
        }
        case 'nomad_action': {
            let res = await callNomad('POST', '/action', args);
            // Self-healing retry: if target not found or ref stale, refresh snapshot and retry once
            if (res && res.success === false && args && args.elementId && !args._retried) {
                try {
                    await callNomad('GET', '/snapshot');
                    const retryRes = await callNomad('POST', '/action', { ...args, _retried: true });
                    if (retryRes && retryRes.success) {
                        retryRes.healed = true;
                        res = retryRes;
                    }
                } catch (e) {}
            }
            return formatToolResponse(res);
        }
        case 'nomad_wait': {
            const res = await callNomad('POST', '/wait', args);
            return formatToolResponse(res);
        }
        case 'nomad_cookies': {
            const act = (args && args.action) || 'get';
            if (act === 'get') {
                const qs = [];
                if (args && args.allDomains) qs.push('allDomains=true');
                if (args && args.tabId) qs.push(`tabId=${encodeURIComponent(args.tabId)}`);
                const qsStr = qs.length ? `?${qs.join('&')}` : '';
                const res = await callNomad('GET', `/cookies${qsStr}`);
                return formatToolResponse(res);
            } else if (act === 'clear') {
                const qs = [];
                if (args && args.allDomains) qs.push('allDomains=true');
                if (args && args.tabId) qs.push(`tabId=${encodeURIComponent(args.tabId)}`);
                const qsStr = qs.length ? `?${qs.join('&')}` : '';
                const res = await callNomad('DELETE', `/cookies${qsStr}`);
                return formatToolResponse(res);
            } else {
                const res = await callNomad('POST', '/cookies', args);
                return formatToolResponse(res);
            }
        }
        case 'nomad_screenshot': {
            const qs = [];
            if (args && args.labeled) qs.push('labeled=true');
            if (args && args.elementId) qs.push(`elementId=${encodeURIComponent(args.elementId)}`);
            if (args && args.clip) {
                const c = args.clip;
                qs.push(`clip=${c.x},${c.y},${c.width},${c.height}`);
            }
            if (args && args.tabId) qs.push(`tabId=${encodeURIComponent(args.tabId)}`);
            const pathStr = qs.length ? `/screenshot?${qs.join('&')}` : '/screenshot';
            const res = await callNomad('GET', pathStr);
            if (res && res._rawImage) {
                const b64 = res._rawImage.toString('base64');
                return {
                    content: [{
                        type: 'image',
                        data: b64,
                        mimeType: 'image/png'
                    }],
                    isError: false
                };
            }
            return formatToolResponse(res, 'Screenshot captured.');
        }
        case 'nomad_evaluate': {
            const res = await callNomad('POST', '/evaluate', args);
            return formatToolResponse(res);
        }
        case 'nomad_dialog': {
            const res = await callNomad('POST', '/dialog', args);
            return formatToolResponse(res);
        }
        case 'nomad_console': {
            const qs = [];
            if (args && args.clear) qs.push('clear=true');
            if (args && args.level) qs.push(`level=${encodeURIComponent(args.level)}`);
            if (args && args.tabId) qs.push(`tabId=${encodeURIComponent(args.tabId)}`);
            const pathStr = qs.length ? `/console?${qs.join('&')}` : '/console';
            const res = await callNomad('GET', pathStr);
            return formatToolResponse(res);
        }
        case 'nomad_network': {
            const qs = [];
            if (args && args.clear) qs.push('clear=true');
            if (args && args.statusFilter) qs.push(`statusFilter=${encodeURIComponent(args.statusFilter)}`);
            if (args && args.tabId) qs.push(`tabId=${encodeURIComponent(args.tabId)}`);
            const pathStr = qs.length ? `/network?${qs.join('&')}` : '/network';
            const res = await callNomad('GET', pathStr);
            return formatToolResponse(res);
        }
        default:
            throw new Error(`Unknown tool: ${name}`);
    }
}

function sendResponse(id, result = null, error = null) {
    const payload = { jsonrpc: '2.0', id };
    if (error) {
        payload.error = error;
    } else {
        payload.result = result;
    }
    process.stdout.write(JSON.stringify(payload) + '\n');
}

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false
});

rl.on('line', async (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;

    let req;
    try {
        req = JSON.parse(trimmed);
    } catch (e) {
        return;
    }

    const { id, method, params } = req;

    if (method === 'initialize') {
        sendResponse(id, {
            protocolVersion: '2024-11-05',
            capabilities: { tools: {} },
            serverInfo: {
                name: 'nomad-browser',
                version: '1.0.0'
            }
        });
    } else if (method === 'notifications/initialized') {
        // Notification, no reply needed
    } else if (method === 'ping') {
        sendResponse(id, {});
    } else if (method === 'tools/list') {
        sendResponse(id, { tools: TOOLS });
    } else if (method === 'tools/call') {
        const toolName = params ? params.name : null;
        const toolArgs = (params && params.arguments) || {};
        try {
            const outcome = await handleToolCall(toolName, toolArgs);
            sendResponse(id, { content: outcome.content, isError: Boolean(outcome.isError) });
        } catch (err) {
            sendResponse(id, {
                content: [{ type: 'text', text: `Error: ${err.message}` }],
                isError: true
            });
        }
    } else {
        if (id !== undefined) {
            sendResponse(id, null, { code: -32601, message: `Method not found: ${method}` });
        }
    }
});
