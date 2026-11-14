//
//  DinoOfflinePage.swift
//  dino
//
//  Created for Dino Browser.
//  Self-contained offline error page with Daniel Linssen-inspired Planetarium stars,
//  Dino's pine/ivory palette (#023121 & #ffe5cc), and playable retro sauropod runner mini-game.
//

import Foundation

enum DinoOfflinePage {
    /// Returns true if the error represents an offline, unreachable host, or network timeout condition.
    static func isOfflineError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorTimedOut,
             NSURLErrorResourceUnavailable,
             NSURLErrorCannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }

    /// Generates the self-contained offline page HTML for the requested URL.
    static func html(for url: URL, error: Error? = nil) -> String {
        let hostOrURL = url.host ?? url.absoluteString
        let safeHost = hostOrURL.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let rawError = error?.localizedDescription ?? "The Internet connection appears to be offline."
        let safeError = rawError.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
          <title>No Internet — Dino</title>
          <style>
            * { box-sizing: border-box; margin: 0; padding: 0; user-select: none; -webkit-user-select: none; }
            html, body {
              width: 100%; height: 100%;
              background-color: #023121;
              color: #ffe5cc;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              overflow: hidden;
            }
            .container {
              display: flex;
              flex-direction: column;
              align-items: center;
              max-width: 640px;
              width: 90%;
              padding: 20px;
              text-align: center;
            }
            #canvas-wrapper {
              position: relative;
              width: 100%;
              max-width: 600px;
              aspect-ratio: 600 / 200;
              margin-bottom: 24px;
              border-radius: 12px;
              overflow: hidden;
              background: radial-gradient(circle at 85% 25%, #064531 0%, #023121 70%);
              box-shadow: 0 12px 32px rgba(0, 0, 0, 0.35), inset 0 0 0 1px rgba(255, 229, 204, 0.12);
              cursor: pointer;
            }
            canvas {
              width: 100%;
              height: 100%;
              image-rendering: -webkit-optimize-contrast;
              image-rendering: pixelated;
              display: block;
            }
            .hint-banner {
              position: absolute;
              bottom: 12px;
              left: 50%;
              transform: translateX(-50%);
              font-size: 11px;
              letter-spacing: 0.08em;
              text-transform: uppercase;
              color: rgba(255, 229, 204, 0.7);
              pointer-events: none;
              transition: opacity 0.3s ease;
            }
            h1 {
              font-size: 22px;
              font-weight: 600;
              letter-spacing: -0.02em;
              margin-bottom: 8px;
              color: #ffe5cc;
            }
            p.desc {
              font-size: 13px;
              line-height: 1.5;
              color: rgba(255, 229, 204, 0.75);
              margin-bottom: 20px;
              max-width: 480px;
            }
            p.error-code {
              font-size: 11px;
              color: rgba(255, 229, 204, 0.45);
              margin-top: -12px;
              margin-bottom: 20px;
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            }
            .actions {
              display: flex;
              gap: 12px;
              align-items: center;
              justify-content: center;
            }
            button.retry-btn {
              background: #ffe5cc;
              color: #023121;
              border: none;
              border-radius: 8px;
              padding: 9px 20px;
              font-size: 13px;
              font-weight: 600;
              cursor: pointer;
              transition: transform 0.15s ease, opacity 0.15s ease;
            }
            button.retry-btn:hover {
              opacity: 0.92;
              transform: translateY(-1px);
            }
            button.retry-btn:active {
              transform: translateY(1px);
            }
            .shortcut-tag {
              font-size: 11px;
              color: rgba(255, 229, 204, 0.4);
            }
          </style>
        </head>
        <body>
          <div class="container">
            <div id="canvas-wrapper" onclick="handleInteraction()">
              <canvas id="gameCanvas" width="600" height="200"></canvas>
              <div id="hintBanner" class="hint-banner">Press Space to Run</div>
            </div>

            <h1>No Internet Connection</h1>
            <p class="desc">Dino couldn't reach <strong>\(safeHost)</strong>. Check your network or play with Dino while you wait.</p>
            <p class="error-code">\(safeError)</p>

            <div class="actions">
              <button class="retry-btn" onclick="retryConnection()">Try Again</button>
              <span class="shortcut-tag">or press ⌘R / ⏎</span>
            </div>
          </div>

          <script>
            function retryConnection() {
              window.location.reload();
            }

            // Keyboard shortcut support
            window.addEventListener('keydown', function(e) {
              if (e.key === ' ' || e.key === 'ArrowUp') {
                e.preventDefault();
                jumpOrStart();
              } else if (e.key === 'Enter' && !isPlaying) {
                retryConnection();
              }
            });

            function handleInteraction() {
              jumpOrStart();
            }

            // --- Game Engine ---
            const canvas = document.getElementById('gameCanvas');
            const ctx = canvas.getContext('2d');
            const hintBanner = document.getElementById('hintBanner');

            const WIDTH = 600;
            const HEIGHT = 200;
            const GROUND_Y = 160;

            let isPlaying = false;
            let isGameOver = false;
            let score = 0;
            let hiScore = parseInt(localStorage.getItem('dino_hi_score') || '0', 10);
            let speed = 4.0;
            let frameCount = 0;

            // Audio clicks
            let audioCtx = null;
            function playBeep(freq, type = 'sine', duration = 0.06) {
              try {
                if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
                if (audioCtx.state === 'suspended') audioCtx.resume();
                const osc = audioCtx.createOscillator();
                const gain = audioCtx.createGain();
                osc.type = type;
                osc.frequency.setValueAtTime(freq, audioCtx.currentTime);
                gain.gain.setValueAtTime(0.08, audioCtx.currentTime);
                gain.gain.exponentialRampToValueAtTime(0.001, audioCtx.currentTime + duration);
                osc.connect(gain);
                gain.connect(audioCtx.destination);
                osc.start();
                osc.stop(audioCtx.currentTime + duration);
              } catch (_) {}
            }

            // Dino character
            const dino = {
              x: 44,
              y: GROUND_Y,
              vy: 0,
              width: 32,
              height: 36,
              grounded: true,
              jumpPower: -9.4,
              gravity: 0.44
            };

            // Stars inspired by Daniel Linssen's Planetarium
            const stars = [];
            for (let i = 0; i < 40; i++) {
              stars.push({
                x: (i * 15.3 + (i * i * 7)) % WIDTH,
                y: 15 + ((i * 37) % (GROUND_Y - 40)),
                size: (i % 5 === 0) ? 2 : 1,
                twinkle: (i % 3 === 0),
                phase: Math.random() * Math.PI * 2
              });
            }

            // Obstacles
            let obstacles = [];
            let nextObstacleTimer = 70;

            function jumpOrStart() {
              if (isGameOver) {
                resetGame();
                return;
              }
              if (!isPlaying) {
                isPlaying = true;
                hintBanner.style.opacity = '0';
              }
              if (dino.grounded) {
                dino.vy = dino.jumpPower;
                dino.grounded = false;
                playBeep(480, 'triangle', 0.08);
              }
            }

            function resetGame() {
              dino.y = GROUND_Y;
              dino.vy = 0;
              dino.grounded = true;
              obstacles = [];
              score = 0;
              speed = 4.0;
              frameCount = 0;
              nextObstacleTimer = 60;
              isGameOver = false;
              isPlaying = true;
            }

            // Draw Pixel Dino (Sauropod silhouette in #ffe5cc)
            function drawDino(x, y, isLegUp, isDead) {
              ctx.fillStyle = '#ffe5cc';
              const px = Math.round(x);
              const py = Math.round(y - dino.height);

              // Head & Snout
              ctx.fillRect(px + 20, py, 10, 8);
              // Eye (cutout)
              if (!isDead) {
                ctx.fillStyle = '#023121';
                ctx.fillRect(px + 26, py + 2, 2, 2);
                ctx.fillStyle = '#ffe5cc';
              } else {
                ctx.fillStyle = '#023121';
                // Cross eye on death
                ctx.fillRect(px + 25, py + 1, 3, 3);
                ctx.fillStyle = '#ffe5cc';
              }
              // Long Graceful Neck
              ctx.fillRect(px + 16, py + 6, 8, 14);

              // Main Body
              ctx.fillRect(px + 6, py + 16, 20, 14);

              // Back tail sloping up/back
              ctx.fillRect(px, py + 18, 6, 6);
              ctx.fillRect(px - 4, py + 16, 4, 4);

              // Legs
              if (!dino.grounded) {
                // Tucked legs during jump
                ctx.fillRect(px + 8, py + 30, 4, 3);
                ctx.fillRect(px + 18, py + 30, 4, 3);
              } else if (isLegUp) {
                // Walking frame A
                ctx.fillRect(px + 8, py + 30, 4, 6);
                ctx.fillRect(px + 18, py + 30, 4, 3);
              } else {
                // Walking frame B
                ctx.fillRect(px + 8, py + 30, 4, 3);
                ctx.fillRect(px + 18, py + 30, 4, 6);
              }
            }

            // Draw Pixel Obstacle (Ancient Monolith / Cactus in #ffe5cc)
            function drawObstacle(obs) {
              ctx.fillStyle = '#ffe5cc';
              const ox = Math.round(obs.x);
              const oy = Math.round(GROUND_Y - obs.height);
              const ow = Math.round(obs.width);
              const oh = Math.round(obs.height);

              // Vertical pillar
              ctx.fillRect(ox + 4, oy, ow - 8, oh);
              // Left arm
              if (obs.type === 1) {
                ctx.fillRect(ox, oy + 8, 4, 10);
                ctx.fillRect(ox, oy + 16, 6, 4);
              }
              // Right arm
              if (obs.type === 2) {
                ctx.fillRect(ox + ow - 4, oy + 6, 4, 12);
                ctx.fillRect(ox + ow - 6, oy + 14, 6, 4);
              }
              // Top cap
              ctx.fillRect(ox + 2, oy, ow - 4, 2);
            }

            // Draw Planetarium Moon & Stars
            function drawSky() {
              // Daniel Linssen Planetarium Celestial Body in top right
              ctx.fillStyle = 'rgba(255, 229, 204, 0.18)';
              ctx.beginPath();
              ctx.arc(520, 45, 28, 0, Math.PI * 2);
              ctx.fill();

              ctx.fillStyle = '#ffe5cc';
              ctx.beginPath();
              ctx.arc(516, 43, 24, 0, Math.PI * 2);
              ctx.fill();

              // Moon craters in deep pine
              ctx.fillStyle = '#023121';
              ctx.beginPath();
              ctx.arc(508, 38, 5, 0, Math.PI * 2);
              ctx.fill();
              ctx.beginPath();
              ctx.arc(526, 48, 4, 0, Math.PI * 2);
              ctx.fill();
              ctx.beginPath();
              ctx.arc(518, 55, 3, 0, Math.PI * 2);
              ctx.fill();

              // Planetarium Twinkling Stars
              for (const s of stars) {
                const alpha = s.twinkle ? (0.4 + 0.5 * Math.sin(frameCount * 0.05 + s.phase)) : 0.65;
                ctx.fillStyle = `rgba(255, 229, 204, ${alpha})`;
                ctx.fillRect(s.x, s.y, s.size, s.size);
              }
            }

            // Ground plane
            let groundOffset = 0;
            function drawGround() {
              ctx.strokeStyle = 'rgba(255, 229, 204, 0.4)';
              ctx.lineWidth = 1;
              ctx.beginPath();
              ctx.moveTo(0, GROUND_Y + 0.5);
              ctx.lineTo(WIDTH, GROUND_Y + 0.5);
              ctx.stroke();

              // Scrolling dashes
              ctx.fillStyle = 'rgba(255, 229, 204, 0.25)';
              for (let x = - (groundOffset % 24); x < WIDTH; x += 24) {
                ctx.fillRect(x, GROUND_Y + 4, 8, 1);
                ctx.fillRect(x + 12, GROUND_Y + 8, 4, 1);
              }
            }

            function drawScores() {
              ctx.font = '12px ui-monospace, SFMono-Regular, Menlo, monospace';
              ctx.fillStyle = 'rgba(255, 229, 204, 0.8)';
              const curStr = String(Math.floor(score)).padStart(5, '0');
              const hiStr = String(Math.floor(hiScore)).padStart(5, '0');
              ctx.fillText(`HI ${hiStr}   ${curStr}`, WIDTH - 140, 24);
            }

            function update() {
              frameCount++;

              if (isPlaying && !isGameOver) {
                score += 0.15;
                speed = Math.min(9.5, 4.0 + (score * 0.004));
                groundOffset += speed;

                if (Math.floor(score) > 0 && Math.floor(score) % 100 === 0 && Math.floor(score) !== Math.floor(score - 0.15)) {
                  playBeep(880, 'square', 0.12);
                }

                // Dino physics
                dino.vy += dino.gravity;
                dino.y += dino.vy;
                if (dino.y >= GROUND_Y) {
                  dino.y = GROUND_Y;
                  dino.vy = 0;
                  dino.grounded = true;
                }

                // Obstacle generation
                nextObstacleTimer -= 1;
                if (nextObstacleTimer <= 0) {
                  const type = Math.floor(Math.random() * 3);
                  const h = 24 + Math.floor(Math.random() * 16);
                  const w = 18 + Math.floor(Math.random() * 8);
                  obstacles.push({ x: WIDTH + 10, y: GROUND_Y, width: w, height: h, type });
                  nextObstacleTimer = Math.floor(65 + Math.random() * 45 - (speed * 2));
                }

                // Move obstacles and collision test
                for (let i = obstacles.length - 1; i >= 0; i--) {
                  const obs = obstacles[i];
                  obs.x -= speed;

                  // Hitbox test with generous forgiving margin
                  const dinoBox = { x: dino.x + 6, y: dino.y - dino.height + 4, w: dino.width - 12, h: dino.height - 4 };
                  const obsBox = { x: obs.x + 3, y: GROUND_Y - obs.height, w: obs.width - 6, h: obs.height };

                  if (dinoBox.x < obsBox.x + obsBox.w &&
                      dinoBox.x + dinoBox.w > obsBox.x &&
                      dinoBox.y < obsBox.y + obsBox.h &&
                      dinoBox.y + dinoBox.h > obsBox.y) {
                    isGameOver = true;
                    playBeep(160, 'sawtooth', 0.22);
                    if (score > hiScore) {
                      hiScore = Math.floor(score);
                      localStorage.setItem('dino_hi_score', String(hiScore));
                    }
                  }

                  if (obs.x + obs.width < -20) {
                    obstacles.splice(i, 1);
                  }
                }
              }

              // Render
              ctx.clearRect(0, 0, WIDTH, HEIGHT);
              drawSky();
              drawGround();

              for (const obs of obstacles) {
                drawObstacle(obs);
              }

              const isLegUp = (Math.floor(frameCount / 6) % 2) === 0;
              drawDino(dino.x, dino.y, isLegUp, isGameOver);
              drawScores();

              if (isGameOver) {
                ctx.fillStyle = 'rgba(2, 49, 33, 0.75)';
                ctx.fillRect(0, 0, WIDTH, HEIGHT);

                ctx.fillStyle = '#ffe5cc';
                ctx.font = '600 16px -apple-system, sans-serif';
                ctx.textAlign = 'center';
                ctx.fillText('G A M E   O V E R', WIDTH / 2, HEIGHT / 2 - 8);

                ctx.font = '11px ui-monospace, SFMono-Regular, monospace';
                ctx.fillStyle = 'rgba(255, 229, 204, 0.7)';
                ctx.fillText('PRESS SPACE OR CLICK TO RETRY', WIDTH / 2, HEIGHT / 2 + 18);
                ctx.textAlign = 'start';
              }

              requestAnimationFrame(update);
            }

            requestAnimationFrame(update);
          </script>
        </body>
        </html>
        """
    }
}
