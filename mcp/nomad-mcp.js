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
        const reqTimeout = Math.max(10000, ((body && (body.timeoutMs || body.durationMs)) || 0) + 5000);
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
            reject(new Error(`Timeout connecting to Nomad at http://${HOST}:${NOMAD_PORT}`));
        });

        req.on('error', (err) => {
            reject(new Error(`Failed to connect to Nomad at http://${HOST}:${NOMAD_PORT} (${err.message}). Ensure Nomad browser is running.`));
        });

        if (payload) {
            req.write(payload);
        }
        req.end();
    });
}

function formatToolResponse(res, customText = null) {
    const isErr = Boolean(res && typeof res === 'object' && (res.error || res.success === false || (res.code && String(res.code).startsWith('EVAL_'))));
    const text = customText !== null ? customText : (typeof res === 'string' ? res : JSON.stringify(res, null, 2));
    return {
        content: [{ type: 'text', text }],
        isError: isErr
    };
}

const TOOLS = [
    {
        name: 'nomad_status',
        description: 'Check if Nomad browser engine is active, get version, tab counts, and current active page info.',
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
        description: 'Capture a token-optimized semantic perception tree (typically 200–1,200 tokens depending on page density, vs 50k–100k+ raw HTML). Extracts visible interactive elements, semantic headings (h1-h3), and images across light and Shadow DOM with assigned IDs ([e1], [e2], ...), bounding coordinates, tag names, roles, accessible text, image src URLs, and occlusion states.',
        inputSchema: {
            type: 'object',
            properties: {},
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
                amount: { type: 'number', description: 'Pixels to scroll for direction fallback' }
            },
            required: ['type'],
            additionalProperties: false
        }
    },
    {
        name: 'nomad_wait',
        description: 'Wait for DOM mutation stability, a specific CSS selector to appear, or a timeout before continuing execution. Essential for SPAs (React, Next.js) to finish rendering.',
        inputSchema: {
            type: 'object',
            properties: {
                mode: {
                    type: 'string',
                    enum: ['stability', 'selector', 'timeout', 'stable', 'idle', 'domStable'],
                    description: 'Wait mode. Default: stability.'
                },
                selector: {
                    type: 'string',
                    description: 'CSS selector to wait for (if provided, mode defaults to "selector")'
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
                }
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
        description: 'Capture a GPU screenshot of the active tab. Set labeled=true to overlay numbered element badges [1], [2] matching the semantic snapshot for vision-grounded models.',
        inputSchema: {
            type: 'object',
            properties: {
                labeled: {
                    type: 'boolean',
                    description: 'If true, renders vision-grounding element number badges over interactive nodes'
                }
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
                }
            },
            required: ['script'],
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
            const res = await callNomad('GET', '/snapshot');
            const summary = res.summary || '';
            const tokens = res.tokenEstimate || 0;
            const text = `=== Nomad Semantic Perception ===\nTokens: ~${tokens}\nURL: ${res.url || ''}\nTitle: ${res.title || ''}\n\n${summary}`;
            return formatToolResponse(res, text);
        }
        case 'nomad_action': {
            const res = await callNomad('POST', '/action', args);
            return formatToolResponse(res);
        }
        case 'nomad_wait': {
            const res = await callNomad('POST', '/wait', args);
            return formatToolResponse(res);
        }
        case 'nomad_cookies': {
            const act = (args && args.action) || 'get';
            if (act === 'get') {
                const qs = args && args.allDomains ? '?allDomains=true' : '';
                const res = await callNomad('GET', `/cookies${qs}`);
                return formatToolResponse(res);
            } else if (act === 'clear') {
                const qs = args && args.allDomains ? '?allDomains=true' : '';
                const res = await callNomad('DELETE', `/cookies${qs}`);
                return formatToolResponse(res);
            } else {
                const res = await callNomad('POST', '/cookies', args);
                return formatToolResponse(res);
            }
        }
        case 'nomad_screenshot': {
            const isLabeled = Boolean(args && args.labeled);
            const pathStr = isLabeled ? '/screenshot?labeled=true' : '/screenshot';
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
