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

const NOMAD_PORT = parseInt(process.env.NOMAD_AGENT_PORT || '9222', 10);
const HOST = '127.0.0.1';

/**
 * Perform an HTTP request to Nomad's local agent server.
 */
function callNomad(method, path, body = null) {
    return new Promise((resolve, reject) => {
        const payload = body ? JSON.stringify(body) : null;
        const options = {
            hostname: HOST,
            port: NOMAD_PORT,
            path: path,
            method: method,
            headers: {
                'Content-Type': 'application/json',
                ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {})
            },
            timeout: 10000
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
        description: 'Navigate the active tab to a new URL.',
        inputSchema: {
            type: 'object',
            properties: {
                url: { type: 'string', description: 'Complete destination URL (e.g. https://github.com)' }
            },
            required: ['url'],
            additionalProperties: false
        }
    },
    {
        name: 'nomad_snapshot',
        description: 'Capture a token-optimized semantic perception tree (~300 tokens vs 100k raw HTML). Extracts visible interactive elements with assigned IDs ([e1], [e2], ...), bounding coordinates, tag names, roles, and text labels.',
        inputSchema: {
            type: 'object',
            properties: {},
            additionalProperties: false
        }
    },
    {
        name: 'nomad_action',
        description: 'Execute an atomic interaction in the active tab (click, type, press key, scroll, highlight). Best used with elementId from nomad_snapshot (e.g. "e1").',
        inputSchema: {
            type: 'object',
            properties: {
                type: {
                    type: 'string',
                    enum: ['click', 'type', 'press', 'scroll', 'highlight'],
                    description: 'Type of action to execute'
                },
                elementId: {
                    type: 'string',
                    description: 'Target element ID from nomad_snapshot (e.g. "e1", "e2")'
                },
                selector: {
                    type: 'string',
                    description: 'CSS selector fallback if elementId is not used'
                },
                text: {
                    type: 'string',
                    description: 'Text to enter (for "type" action) or key name (for "press" action, e.g. "Enter")'
                },
                x: { type: 'number', description: 'Viewport X coordinate fallback' },
                y: { type: 'number', description: 'Viewport Y coordinate fallback' },
                scrollDeltaY: { type: 'number', description: 'Pixels to scroll down (positive) or up (negative) for "scroll"' }
            },
            required: ['type'],
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
                script: { type: 'string', description: 'JavaScript code to execute' }
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
            return [{ type: 'text', text: JSON.stringify(res, null, 2) }];
        }
        case 'nomad_tabs': {
            const res = await callNomad('GET', '/tabs');
            return [{ type: 'text', text: JSON.stringify(res, null, 2) }];
        }
        case 'nomad_new_tab': {
            const res = await callNomad('POST', '/tabs/new', args);
            return [{ type: 'text', text: JSON.stringify(res, null, 2) }];
        }
        case 'nomad_switch_tab': {
            const res = await callNomad('POST', '/tabs/switch', args);
            return [{ type: 'text', text: JSON.stringify(res, null, 2) }];
        }
        case 'nomad_close_tab': {
            const res = await callNomad('POST', '/tabs/close', args);
            return [{ type: 'text', text: JSON.stringify(res, null, 2) }];
        }
        case 'nomad_navigate': {
            const res = await callNomad('POST', '/navigate', args);
            return [{ type: 'text', text: JSON.stringify(res, null, 2) }];
        }
        case 'nomad_snapshot': {
            const res = await callNomad('GET', '/snapshot');
            const summary = res.summary || '';
            const tokens = res.tokenEstimate || 0;
            const text = `=== Nomad Semantic Perception ===\nTokens: ~${tokens}\nURL: ${res.url || ''}\nTitle: ${res.title || ''}\n\n${summary}`;
            return [{ type: 'text', text }];
        }
        case 'nomad_action': {
            const res = await callNomad('POST', '/action', args);
            return [{ type: 'text', text: JSON.stringify(res, null, 2) }];
        }
        case 'nomad_screenshot': {
            const isLabeled = Boolean(args && args.labeled);
            const path = isLabeled ? '/screenshot?labeled=true' : '/screenshot';
            const res = await callNomad('GET', path);
            if (res && res._rawImage) {
                const b64 = res._rawImage.toString('base64');
                return [{
                    type: 'image',
                    data: b64,
                    mimeType: 'image/png'
                }];
            }
            return [{ type: 'text', text: 'Screenshot captured.' }];
        }
        case 'nomad_evaluate': {
            const res = await callNomad('POST', '/evaluate', args);
            return [{ type: 'text', text: JSON.stringify(res, null, 2) }];
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
            const content = await handleToolCall(toolName, toolArgs);
            sendResponse(id, { content, isError: false });
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
