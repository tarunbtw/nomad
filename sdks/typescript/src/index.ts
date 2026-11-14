/**
 * Dino Browser TypeScript SDK (v0.41.0)
 * Ultra-light native macOS agentic browser driver, token-optimized perception, and Unix socket bridge.
 */

import * as http from 'http';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

export interface DinoOptions {
  port?: number;
  host?: string;
  socketPath?: string;
  token?: string;
}

export interface SnapshotOptions {
  mode?: 'text' | 'json';
  limit?: number;
  offset?: number;
  viewportOnly?: boolean;
  coords?: boolean;
  includeCoords?: boolean;
  target?: string;
  role?: string;
  text?: string;
  depth?: number;
}

export interface ActionOptions {
  target?: string;
  native?: boolean;
  submit?: boolean;
  clear?: boolean;
  wait?: boolean;
  modifiers?: string[];
  tabId?: string;
}

export interface ScreenshotOptions {
  file?: string;
  labeled?: boolean;
  crop?: boolean;
  clip?: { x: number; y: number; width: number; height: number };
  elementId?: string;
  tabId?: string;
}

export interface LaunchOptions {
  headless?: boolean;
  profile?: string;
  idleTimeout?: number;
  port?: number;
  binPath?: string;
  args?: string[];
}

export interface WaitOptions {
  mode?: 'auto' | 'stability' | 'selector' | 'networkidle' | 'url';
  selector?: string;
  timeout?: number;
  duration?: number;
  text?: string;
  tabId?: string;
}

export class Dino {
  readonly port: number;
  readonly host: string;
  readonly socketPath?: string;
  readonly token: string;

  constructor(options: DinoOptions = {}) {
    if (os.platform() !== 'darwin') {
      console.warn('Dino is a native Apple Silicon browser engine and runs on macOS.');
    }
    this.port = options.port ?? 9222;
    this.host = options.host ?? '127.0.0.1';
    this.socketPath = options.socketPath ?? Dino.resolveSocketPath();
    this.token = options.token ?? Dino.loadToken();
  }

  static loadToken(): string {
    if (process.env.DINO_TOKEN) return process.env.DINO_TOKEN.trim();
    const dinoTokenFile = path.join(os.homedir(), '.dino', 'agent-token');
    try {
      if (fs.existsSync(dinoTokenFile)) {
        return fs.readFileSync(dinoTokenFile, 'utf8').trim();
      }
    } catch {
      // fallback
    }
    return '';
  }

  static resolveSocketPath(profile?: string): string | undefined {
    const dinoDir = path.join(os.homedir(), '.dino');
    const workersDir = path.join(dinoDir, 'workers');

    // 1. If profile specified, search worker descriptors
    if (profile && fs.existsSync(workersDir)) {
      try {
        const files = fs.readdirSync(workersDir);
        for (const file of files) {
          if (file.startsWith('worker-') && file.endsWith('.json')) {
            const raw = fs.readFileSync(path.join(workersDir, file), 'utf8');
            const data = JSON.parse(raw);
            if (data.profile === profile && fs.existsSync(data.socketPath)) {
              return data.socketPath;
            }
          }
        }
      } catch {}
    }

    // 2. Default socket ~/.dino/dino.sock
    const defaultSock = path.join(dinoDir, 'dino.sock');
    if (fs.existsSync(defaultSock)) return defaultSock;

    // 3. Fallback to any active worker socket
    if (fs.existsSync(workersDir)) {
      try {
        const files = fs.readdirSync(workersDir);
        const sock = files.find((f: string) => f.endsWith('.sock'));
        if (sock) return path.join(workersDir, sock);
      } catch {}
    }
    return undefined;
  }

  static resolveBinary(autoDownload: boolean = true): string | null {
    if (process.env.DINO_BIN && fs.existsSync(process.env.DINO_BIN)) {
      return process.env.DINO_BIN;
    }
    const appPath = '/Applications/Dino.app/Contents/MacOS/dino';
    if (fs.existsSync(appPath)) return appPath;

    const userBin = path.join(os.homedir(), '.dino', 'bin', 'dino');
    if (fs.existsSync(userBin)) return userBin;

    try {
      const { execSync } = require('child_process');
      const p = execSync('which dino 2>/dev/null', { encoding: 'utf8' }).trim();
      if (p && fs.existsSync(p)) return p;
    } catch {}

    if (autoDownload && os.platform() === 'darwin') {
      const { execSync } = require('child_process');
      const version = '0.42';
      const url = `https://github.com/tarunbtw/dino/releases/download/v${version}/Dino-${version}.zip`;
      const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dino-dl-'));
      const zipPath = path.join(tmpDir, `Dino-${version}.zip`);
      const extDir = path.join(tmpDir, 'ext');
      try {
        execSync(`curl -fsSL "${url}" -o "${zipPath}"`, { stdio: 'ignore' });
        fs.mkdirSync(extDir, { recursive: true });
        execSync(`ditto -x -k "${zipPath}" "${extDir}"`, { stdio: 'ignore' });
        let bin = path.join(extDir, 'Dino.app', 'Contents', 'MacOS', 'dino');
        if (!fs.existsSync(bin)) bin = path.join(extDir, 'Dino.app', 'Contents', 'MacOS', 'Dino');
        if (fs.existsSync(bin)) {
          fs.mkdirSync(path.dirname(userBin), { recursive: true, mode: 0o755 });
          fs.copyFileSync(bin, userBin);
          fs.chmodSync(userBin, 0o755);
          return userBin;
        }
      } catch {} finally {
        try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}
      }
    }
    return null;
  }

  static async waitForSocket(profile?: string, timeoutMs: number = 3000): Promise<string> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const sock = Dino.resolveSocketPath(profile);
      if (sock && fs.existsSync(sock)) return sock;
      await new Promise(r => setTimeout(r, 50));
    }
    throw new Error(`Dino socket not found after ${timeoutMs}ms. Ensure engine is running.`);
  }

  /**
   * Spawns an isolated background Dino engine and returns a connected Dino client instance.
   */
  static async launch(options: LaunchOptions = {}): Promise<Dino> {
    const headless = options.headless ?? true;
    const profile = options.profile ?? 'agent';
    const idleTimeout = options.idleTimeout ?? 60;
    const binary = options.binPath ?? Dino.resolveBinary(true);

    if (!binary) {
      throw new Error('Dino binary not found. Run "npx dino-browser install" or install /Applications/Dino.app');
    }

    const spawnArgs = [...(options.args || [])];
    if (headless && !spawnArgs.includes('--headless')) spawnArgs.push('--headless');
    if (!spawnArgs.includes('--profile')) spawnArgs.push('--profile', profile);
    if (!spawnArgs.includes('--idle-timeout')) spawnArgs.push('--idle-timeout', String(idleTimeout));
    if (options.port) spawnArgs.push('--port', String(options.port));

    const { spawn } = require('child_process');
    const child = spawn(binary, spawnArgs, {
      detached: true,
      stdio: 'ignore',
      env: process.env
    });
    child.unref();

    const socketPath = await Dino.waitForSocket(profile, 4000);
    return new Dino({ socketPath, port: options.port });
  }

  private request<T = any>(method: string, endpoint: string, body?: any, timeoutMs: number = 30000): Promise<T> {
    return new Promise((resolve, reject) => {
      const payload = body ? JSON.stringify(body) : undefined;
      const headers: Record<string, string | number> = {
        'Content-Type': 'application/json'
      };
      if (this.token) {
        headers['Authorization'] = `Bearer ${this.token}`;
      }
      if (payload) {
        headers['Content-Length'] = Buffer.byteLength(payload);
      }

      const reqOptions: http.RequestOptions = {
        method,
        headers,
        timeout: timeoutMs
      };

      if (this.socketPath && fs.existsSync(this.socketPath)) {
        reqOptions.socketPath = this.socketPath;
        reqOptions.path = endpoint;
      } else {
        reqOptions.host = this.host;
        reqOptions.port = this.port;
        reqOptions.path = endpoint;
      }

      const req = http.request(reqOptions, (res) => {
        const chunks: Buffer[] = [];
        res.on('data', chunk => chunks.push(chunk));
        res.on('end', () => {
          const raw = Buffer.concat(chunks).toString('utf8');
          if (res.statusCode && res.statusCode >= 400) {
            return reject(new Error(`Dino HTTP ${res.statusCode}: ${raw}`));
          }
          try {
            const parsed = JSON.parse(raw);
            resolve(parsed as T);
          } catch {
            resolve(raw as unknown as T);
          }
        });
      });

      req.on('timeout', () => {
        req.destroy();
        reject(new Error(`Dino request timed out after ${timeoutMs}ms`));
      });

      req.on('error', (err) => reject(err));

      if (payload) {
        req.write(payload);
      }
      req.end();
    });
  }

  // --- Status & Tabs ---

  async status() {
    return this.request('GET', '/status');
  }

  async tabs(): Promise<any[]> {
    const res = await this.request('GET', '/tabs');
    return res.tabs || [];
  }

  async newTab(url?: string, options: { isGhost?: boolean; select?: boolean } = {}) {
    return this.request('POST', '/tabs/new', {
      url: url || '',
      isGhost: options.isGhost ?? false,
      select: options.select ?? true
    });
  }

  async switchTab(tabIdOrIndex: string | number) {
    const body = typeof tabIdOrIndex === 'number' ? { index: tabIdOrIndex } : { tabId: tabIdOrIndex };
    return this.request('POST', '/tabs/switch', body);
  }

  async closeTab(tabIdOrIndex?: string | number) {
    const body = typeof tabIdOrIndex === 'number' ? { index: tabIdOrIndex } : (tabIdOrIndex ? { tabId: tabIdOrIndex } : {});
    return this.request('POST', '/tabs/close', body);
  }

  // --- Navigation ---

  async goto(url: string, options: { allowLocalFiles?: boolean } = {}) {
    return this.request('POST', '/navigate', {
      action: 'url',
      url,
      allowLocalFiles: options.allowLocalFiles ?? false
    });
  }

  async back() {
    return this.request('POST', '/navigate', { action: 'back' });
  }

  async forward() {
    return this.request('POST', '/navigate', { action: 'forward' });
  }

  async reload() {
    return this.request('POST', '/navigate', { action: 'reload' });
  }

  // --- Perception & Inspection ---

  async snapshot(options: SnapshotOptions = {}) {
    const params = new URLSearchParams();
    if (options.mode) params.append('mode', options.mode);
    if (options.limit !== undefined) params.append('limit', String(options.limit));
    if (options.offset !== undefined) params.append('offset', String(options.offset));
    if (options.viewportOnly) params.append('viewportOnly', 'true');
    if (options.target) params.append('target', options.target);
    if (options.role) params.append('role', options.role);
    if (options.text) params.append('text', options.text);
    if (options.depth !== undefined) params.append('depth', String(options.depth));
    const qs = params.toString();
    return this.request('GET', qs ? `/snapshot?${qs}` : '/snapshot');
  }

  async diff(tabId?: string) {
    const endpoint = tabId ? `/diff?tabId=${encodeURIComponent(tabId)}` : '/diff';
    return this.request('GET', endpoint);
  }

  async find(query: { role?: string; text?: string; selector?: string; viewportOnly?: boolean }) {
    const params = new URLSearchParams();
    if (query.role) params.append('role', query.role);
    if (query.text) params.append('text', query.text);
    if (query.selector) params.append('selector', query.selector);
    if (query.viewportOnly) params.append('viewportOnly', 'true');
    return this.request('GET', `/find?${params.toString()}`);
  }

  // --- Atomic Actions ---

  async click(target: string, options: ActionOptions = {}) {
    return this.request('POST', '/action', {
      action: 'click',
      target,
      native: options.native ?? false,
      tabId: options.tabId
    });
  }

  async dblclick(target: string, options: ActionOptions = {}) {
    return this.request('POST', '/action', {
      action: 'dblclick',
      target,
      native: options.native ?? false,
      tabId: options.tabId
    });
  }

  async type(target: string, text: string, options: ActionOptions = {}) {
    return this.request('POST', '/action', {
      action: 'type',
      target,
      text,
      submit: options.submit ?? false,
      clear: options.clear ?? false,
      native: options.native ?? false,
      tabId: options.tabId
    });
  }

  async press(key: string, options: { modifiers?: string[]; tabId?: string } = {}) {
    return this.request('POST', '/action', {
      action: 'press',
      key,
      modifiers: options.modifiers,
      tabId: options.tabId
    });
  }

  async scroll(direction: 'up' | 'down' | 'left' | 'right' = 'down', amount: number = 300, options: { native?: boolean; tabId?: string } = {}) {
    return this.request('POST', '/action', {
      action: 'scroll',
      direction,
      amount,
      native: options.native ?? false,
      tabId: options.tabId
    });
  }

  async drag(from: string, to: string, options: { native?: boolean; tabId?: string } = {}) {
    return this.request('POST', '/action', {
      action: 'drag',
      target: from,
      toTarget: to,
      native: options.native ?? true,
      tabId: options.tabId
    });
  }

  async hover(target: string, options: { tabId?: string } = {}) {
    return this.request('POST', '/action', {
      action: 'hover',
      target,
      tabId: options.tabId
    });
  }

  async wait(options: WaitOptions = {}) {
    return this.request('POST', '/wait', {
      mode: options.mode || 'auto',
      selector: options.selector,
      timeout: options.timeout,
      duration: options.duration,
      text: options.text,
      tabId: options.tabId
    });
  }

  async evaluate(expression: string, options: { world?: 'isolated' | 'page'; tabId?: string } = {}) {
    const res = await this.request('POST', '/evaluate', {
      expression,
      world: options.world || 'isolated',
      tabId: options.tabId
    });
    return res.result;
  }

  // --- Vision & Screenshots ---

  async screenshot(options: ScreenshotOptions = {}): Promise<Buffer> {
    const params = new URLSearchParams();
    if (options.labeled) params.append('labeled', 'true');
    if (options.crop) params.append('somCrop', 'true');
    if (options.elementId) params.append('elementId', options.elementId);
    if (options.clip) {
      params.append('clip', `${options.clip.x},${options.clip.y},${options.clip.width},${options.clip.height}`);
    }
    if (options.tabId) params.append('tabId', options.tabId);

    const qs = params.toString();
    const endpoint = qs ? `/screenshot?${qs}` : '/screenshot';

    return new Promise((resolve, reject) => {
      const reqOptions: http.RequestOptions = {
        method: 'GET',
        headers: this.token ? { 'Authorization': `Bearer ${this.token}` } : {}
      };
      if (this.socketPath && fs.existsSync(this.socketPath)) {
        reqOptions.socketPath = this.socketPath;
        reqOptions.path = endpoint;
      } else {
        reqOptions.host = this.host;
        reqOptions.port = this.port;
        reqOptions.path = endpoint;
      }

      const req = http.request(reqOptions, (res) => {
        const chunks: Buffer[] = [];
        res.on('data', chunk => chunks.push(chunk));
        res.on('end', () => {
          const buf = Buffer.concat(chunks);
          if (options.file) {
            fs.writeFileSync(options.file, buf);
          }
          resolve(buf);
        });
      });
      req.on('error', reject);
      req.end();
    });
  }

  // --- Subsystems ---

  readonly playbook = {
    record: (name: string) => this.request('POST', '/playbook/record', { name }),
    stop: () => this.request('POST', '/playbook/stop'),
    run: (name: string, variables: Record<string, string> = {}) =>
      this.request('POST', '/playbook/replay', { name, variables }),
    list: () => this.request('GET', '/playbook/list'),
    export: (name: string) => this.request('GET', `/playbook/export?name=${encodeURIComponent(name)}`),
    delete: (name: string) => this.request('DELETE', `/playbook?name=${encodeURIComponent(name)}`)
  };

  readonly route = {
    block: (pattern: string) => this.request('POST', '/route', { pattern, action: 'abort' }),
    mock: (pattern: string, body: any, status: number = 200, headers?: Record<string, string>) =>
      this.request('POST', '/route', { pattern, action: 'mock', body, status, headers }),
    list: () => this.request('GET', '/route/list'),
    clear: () => this.request('DELETE', '/route')
  };

  readonly hitl = {
    status: () => this.request('GET', '/hitl/status'),
    resolve: () => this.request('POST', '/hitl/resolve')
  };
}

export const dino = new Dino();
export default Dino;
