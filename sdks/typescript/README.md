# Dino Browser (`dino-browser`)

Official TypeScript/JavaScript SDK and CLI for [Dino](https://github.com/tarunbtw/dino) — the ultra-light native macOS WebKit browser engine built for AI agents.

- **Zero Heavy Drivers**: <15MB native binary, <80ms startup, ~35MB RAM (vs 450MB+ Chromium).
- **Auto-Download Engine**: Works out-of-the-box via `npx dino-browser` or `import { Dino } from 'dino-browser'`. Automatically finds `/Applications/Dino.app` or downloads the native engine from GitHub Releases into `~/.dino/bin/dino`.
- **Token-Optimized Perception**: Compact accessibility tree (`dino snap -v`), DOM diffs (sub-50 tokens), and vision Set-of-Marks badges.
- **Native Hardware Input**: Direct AppKit & CGEvent keyboard/mouse synthesis.

---

## CLI Usage (Zero Install via npx)

```bash
# Navigate to a URL
npx dino-browser goto https://example.com

# Token-optimized perception (~400 tokens)
npx dino-browser snap -v

# Click or type by deterministic element ID
npx dino-browser click e2
npx dino-browser type e3 "Hello world" --submit

# Capture vision-grounded screenshot with element badges
npx dino-browser shot page.png -l --crop

# Explicitly download or update native engine
npx dino-browser install
```

---

## SDK Usage

```bash
npm install dino-browser
```

```typescript
import { Dino } from 'dino-browser';

// Auto-connect to running Dino GUI or launch an isolated background headless worker
const dino = await Dino.launch({ profile: 'agent' });

// 1. Navigate
await dino.goto('https://html.duckduckgo.com/html/');

// 2. Token-Optimized Viewport Perception (~400 tokens)
const tree = await dino.snapshot({ viewportOnly: true, coords: true });
console.log(tree);

// 3. Native & Dynamic Interactions
await dino.type('e2', 'Apple Silicon M4 Max', { submit: true });
await dino.wait();

// 4. Differential Perception (Sub-50 tokens for sequential turns!)
const diff = await dino.diff();
console.log(`DOM Mutations: +${diff.addedCount}, Tokens: ${diff.tokenEstimate}`);

// 5. Parameterized Playbooks (0 LLM tokens!)
await dino.playbook.run('search_flow', { query: 'Apple Silicon' });

// 6. Network Interception
await dino.route.block('*://*.doubleclick.net/**');
await dino.route.mock('*/api/user', { name: 'Alice', tier: 'pro' });
```

---

## License

MIT © [Tarun](https://github.com/tarunbtw)
