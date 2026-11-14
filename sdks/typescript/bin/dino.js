#!/usr/bin/env node

/**
 * Dino Browser CLI Wrapper
 * Resolves local Dino.app installation, global binary, ~/.dino/bin/dino,
 * or auto-downloads the native macOS engine from GitHub Releases.
 */

const { spawn, execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const DINO_VERSION = '0.44';
const GITHUB_REPO = 'tarunbtw/dino';

function downloadBinary(targetPath) {
  if (os.platform() !== 'darwin') {
    console.error('\x1b[31m[dino]\x1b[0m Dino is an ultra-light native macOS WebKit browser engine and requires macOS.');
    process.exit(1);
  }

  const url = `https://github.com/${GITHUB_REPO}/releases/download/v${DINO_VERSION}/Dino-${DINO_VERSION}.zip`;
  console.log(`\x1b[36m[dino]\x1b[0m Downloading native macOS engine (v${DINO_VERSION})...`);

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dino-download-'));
  const zipPath = path.join(tmpDir, `Dino-${DINO_VERSION}.zip`);
  const extractDir = path.join(tmpDir, 'extracted');

  try {
    execSync(`curl -fsSL "${url}" -o "${zipPath}"`, { stdio: 'inherit' });
    fs.mkdirSync(extractDir, { recursive: true });
    execSync(`ditto -x -k "${zipPath}" "${extractDir}"`, { stdio: 'ignore' });

    let binary = path.join(extractDir, 'Dino.app', 'Contents', 'MacOS', 'dino');
    if (!fs.existsSync(binary)) {
      binary = path.join(extractDir, 'Dino.app', 'Contents', 'MacOS', 'Dino');
    }

    if (!fs.existsSync(binary)) {
      throw new Error('Dino binary not found inside release archive.');
    }

    fs.mkdirSync(path.dirname(targetPath), { recursive: true, mode: 0o755 });
    fs.copyFileSync(binary, targetPath);
    fs.chmodSync(targetPath, 0o755);
    console.log(`\x1b[32m[dino]\x1b[0m Native engine installed successfully to ${targetPath}`);
    return targetPath;
  } catch (err) {
    console.error(`\x1b[31m[dino]\x1b[0m Failed to download binary: ${err.message}`);
    process.exit(1);
  } finally {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}
  }
}

function resolveBinary(autoDownload = true) {
  // 1. Check custom environment variable
  if (process.env.DINO_BIN && fs.existsSync(process.env.DINO_BIN)) {
    return process.env.DINO_BIN;
  }

  // 2. Check /Applications/Dino.app
  const appPath = '/Applications/Dino.app/Contents/MacOS/dino';
  if (fs.existsSync(appPath)) {
    return appPath;
  }

  // 3. Check ~/.dino/bin/dino
  const userBin = path.join(os.homedir(), '.dino', 'bin', 'dino');
  if (fs.existsSync(userBin)) {
    return userBin;
  }

  // 4. Check PATH via 'which dino'
  try {
    const p = execSync('which dino 2>/dev/null', { encoding: 'utf8' }).trim();
    if (p && fs.existsSync(p)) {
      return p;
    }
  } catch {}

  // 5. Tier 3: Auto-download fallback
  if (autoDownload) {
    return downloadBinary(userBin);
  }

  return null;
}

const args = process.argv.slice(2);

// Explicit install trigger: "npx dino install"
if (args[0] === 'install') {
  const userBin = path.join(os.homedir(), '.dino', 'bin', 'dino');
  downloadBinary(userBin);
  process.exit(0);
}

const binary = resolveBinary(true);

const child = spawn(binary, args, {
  stdio: 'inherit',
  env: process.env
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
  } else {
    process.exit(code ?? 0);
  }
});
