---
name: add-token-cycling
description: Add OAuth token cycling to the credential proxy. Loads a pool of tokens from ~/.config/nanoclaw/tokens.env and auto-cycles on 429 or 401 errors. Triggers on "token cycling", "rate limit", "token pool", "429", "credential cycling", "multiple tokens".
---

# Add Token Cycling

Adds automatic OAuth token cycling to `src/credential-proxy.ts`. When one token hits a 429 (rate limit) or 401 (auth failure), the proxy automatically tries the next token in the pool. Single-token setups are unaffected.

## Prerequisites

- NanoClaw with the credential proxy already running (`src/credential-proxy.ts`)
- At least one additional OAuth token to add to the pool

## Phase 1: Create the Tokens File

Create `~/.config/nanoclaw/tokens.env` with fallback tokens. The primary token from `.env` is always used first; this file adds fallbacks.

```bash
mkdir -p ~/.config/nanoclaw
cat > ~/.config/nanoclaw/tokens.env << 'EOF'
# Account 2
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oauthXXX-your-second-token

# Account 3
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oauthXXX-your-third-token
EOF
```

Format rules:
- One `CLAUDE_CODE_OAUTH_TOKEN=xxx` per line
- Tokens must start with `sk-ant-` to be recognized
- Lines starting with `#` are used as friendly names for that token in logs
- Empty lines and other keys are ignored
- Quotes around values are stripped automatically

## Phase 2: Token Loading

The `loadFallbackTokens()` function in `src/credential-proxy.ts` reads the tokens file:

```typescript
const TOKENS_FILE = path.join(
  process.env.HOME || '',
  '.config',
  'nanoclaw',
  'tokens.env',
);

interface NamedToken {
  name: string;
  token: string;
}

function loadFallbackTokens(): NamedToken[] {
  try {
    const content = fs.readFileSync(TOKENS_FILE, 'utf-8');
    const tokens: NamedToken[] = [];
    let lastComment = '';
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (trimmed.startsWith('#')) {
        lastComment = trimmed.slice(1).trim();
        continue;
      }
      if (!trimmed) continue;
      const eqIdx = trimmed.indexOf('=');
      if (eqIdx === -1) continue;
      const key = trimmed.slice(0, eqIdx).trim();
      let value = trimmed.slice(eqIdx + 1).trim();
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }
      if (value && value.startsWith('sk-ant-')) {
        tokens.push({ name: lastComment || key, token: value });
      }
      lastComment = '';
    }
    return tokens;
  } catch {
    return [];
  }
}
```

## Phase 3: Token Pool Construction

In `startCredentialProxy()`, the pool is built with the primary token first, then fallbacks deduplicated:

```typescript
const fallbacks = loadFallbackTokens();
const tokenPool: NamedToken[] = [];
const seen = new Set<string>();
const primaryEntry: NamedToken = {
  name: 'primary (.env)',
  token: primaryToken,
};
for (const entry of [primaryEntry, ...fallbacks]) {
  if (entry.token && !seen.has(entry.token)) {
    tokenPool.push(entry);
    seen.add(entry.token);
  }
}

let currentTokenIdx = 0;
```

On startup, if multiple tokens are loaded, the proxy logs:

```
Credential proxy loaded token pool for automatic cycling { tokenCount: 3, tokens: ['primary (.env)', 'Account 2', 'Account 3'] }
```

## Phase 4: Cycling Logic

The cycling happens only for OAuth mode with multiple tokens and requests that have an `Authorization` header:

```typescript
// OAuth with multiple tokens: try current, cycle on 429/401
const startIdx = currentTokenIdx;
let tried = 0;

while (tried < tokenPool.length) {
  const token = tokenPool[currentTokenIdx];
  const headers = buildHeaders(req, body.length, token);

  const result = await proxyRequest(opts, body, makeRequest);

  if (
    (result.status === 429 || result.status === 401) &&
    tried < tokenPool.length - 1
  ) {
    const prevName = tokenPool[currentTokenIdx].name;
    currentTokenIdx = (currentTokenIdx + 1) % tokenPool.length;
    const nextName = tokenPool[currentTokenIdx].name;
    logger.warn(
      { status: result.status, from: prevName, to: nextName, url: req.url },
      'Rate limited or auth failed, cycling token',
    );
    tried++;
    continue;
  }

  // Either success, or exhausted all tokens — return whatever we got
  res.writeHead(result.status, result.headers);
  res.end(result.body);
  return;
}
```

Key behaviors:
- On 429 or 401, cycles to the next token and retries the request
- Wraps around the pool (round-robin)
- If all tokens are exhausted, returns the last response as-is
- The `currentTokenIdx` persists across requests — subsequent requests start with the last working token
- On successful cycle, logs: `Token cycled successfully { activeToken: 'Account 2' }`

## Phase 5: What Stays Unchanged

- **Single-token setups**: If only one token exists (no `tokens.env` or same token repeated), the proxy uses the simple streaming path with zero overhead
- **API key mode**: Token cycling only applies to OAuth mode. API key auth (`x-api-key` header) always uses `ANTHROPIC_API_KEY` from `.env`
- **Non-auth requests**: Requests without an `Authorization` header (post-exchange API calls using `x-api-key`) pass through without cycling
- **Container isolation**: Containers still see placeholder tokens — the proxy injects real credentials

## Verify

```bash
npm run build
```

Restart the service:

```bash
launchctl kickstart -k gui/$(id -u)/com.nanoclaw  # macOS
```

Check logs for token pool loading:

```bash
grep "token pool" logs/nanoclaw.log
```

Expected: `Credential proxy loaded token pool for automatic cycling`

To test cycling, send requests until a 429 occurs. Check logs for:
- `Rate limited or auth failed, cycling token`
- `Token cycled successfully`

## Architecture

```
Container makes API request
  -> Credential proxy receives it
  -> Injects real token from pool[currentTokenIdx]
  -> Forwards to api.anthropic.com
  -> If 429/401 and more tokens available:
       -> Increment currentTokenIdx (wraps around)
       -> Retry with next token
  -> Return response to container
```

### Token Priority

1. Primary token from `.env` (`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_AUTH_TOKEN`)
2. Fallback tokens from `~/.config/nanoclaw/tokens.env` (in file order)
3. Duplicate tokens are deduplicated (by value)

## Removal

```bash
# Remove the tokens file
rm ~/.config/nanoclaw/tokens.env
```

No code changes needed — without the file, `loadFallbackTokens()` returns an empty array and the proxy uses only the primary token.

To fully remove the cycling code from `src/credential-proxy.ts`:
- Remove `loadFallbackTokens()`, `NamedToken` interface, `TOKENS_FILE` constant
- Remove `tokenPool`, `currentTokenIdx`, and the while-loop cycling logic
- Simplify back to single-token proxy

## Troubleshooting

- **Tokens not loading** — Check that `~/.config/nanoclaw/tokens.env` exists, is readable, and tokens start with `sk-ant-`. Run `cat ~/.config/nanoclaw/tokens.env` to verify format.
- **"Credential proxy loaded token pool" not in logs** — Either the file doesn't exist, contains no valid tokens, or the proxy is in API key mode (cycling is OAuth-only).
- **All tokens getting 401** — Tokens may be expired or revoked. Re-authenticate and update the tokens file.
- **Cycling happens too often** — One or more tokens in the pool may be invalid. Check which token name appears in the `from` field of cycling log entries and remove/replace it.
- **No cycling on 429** — Verify you have more than one unique token in the pool. The proxy logs `tokenCount` on startup.
