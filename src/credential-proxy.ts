// ABOUTME: Credential proxy for container isolation with automatic token cycling.
// ABOUTME: Injects real credentials so containers never see them; cycles on 429/401.
import fs from 'fs';
import path from 'path';
import { createServer, Server } from 'http';
import { request as httpsRequest } from 'https';
import { request as httpRequest, IncomingMessage, RequestOptions } from 'http';

import { readEnvFile } from './env.js';
import { logger } from './logger.js';

export type AuthMode = 'api-key' | 'oauth';

export interface ProxyConfig {
  authMode: AuthMode;
}

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

/** Load all OAuth tokens from the tokens.env file with their names. */
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
        // Use the comment above as a friendly name, or fall back to the key
        tokens.push({ name: lastComment || key, token: value });
      }
      lastComment = '';
    }
    return tokens;
  } catch {
    return [];
  }
}

/** Make an upstream request and return the full response (status, headers, body). */
function proxyRequest(
  opts: RequestOptions,
  body: Buffer,
  makeRequest: typeof httpsRequest,
): Promise<{ status: number; headers: IncomingMessage['headers']; body: Buffer }> {
  return new Promise((resolve, reject) => {
    const upstream = makeRequest(opts, (upRes) => {
      const chunks: Buffer[] = [];
      upRes.on('data', (c) => chunks.push(c));
      upRes.on('end', () => {
        resolve({
          status: upRes.statusCode!,
          headers: upRes.headers,
          body: Buffer.concat(chunks),
        });
      });
    });
    upstream.on('error', reject);
    upstream.write(body);
    upstream.end();
  });
}

export function startCredentialProxy(
  port: number,
  host = '127.0.0.1',
): Promise<Server> {
  const secrets = readEnvFile([
    'ANTHROPIC_API_KEY',
    'CLAUDE_CODE_OAUTH_TOKEN',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_BASE_URL',
  ]);

  const authMode: AuthMode = secrets.ANTHROPIC_API_KEY ? 'api-key' : 'oauth';
  const primaryToken =
    secrets.CLAUDE_CODE_OAUTH_TOKEN || secrets.ANTHROPIC_AUTH_TOKEN || '';

  // Build token pool: primary first, then fallbacks (deduplicated)
  const fallbacks = loadFallbackTokens();
  const tokenPool: NamedToken[] = [];
  const seen = new Set<string>();
  const primaryEntry: NamedToken = { name: 'primary (.env)', token: primaryToken };
  for (const entry of [primaryEntry, ...fallbacks]) {
    if (entry.token && !seen.has(entry.token)) {
      tokenPool.push(entry);
      seen.add(entry.token);
    }
  }

  // Track which token index to use next (round-robin on failure)
  let currentTokenIdx = 0;

  if (authMode === 'oauth' && tokenPool.length > 1) {
    logger.info(
      { tokenCount: tokenPool.length, tokens: tokenPool.map((t) => t.name) },
      'Credential proxy loaded token pool for automatic cycling',
    );
  }

  const upstreamUrl = new URL(
    secrets.ANTHROPIC_BASE_URL || 'https://api.anthropic.com',
  );
  const isHttps = upstreamUrl.protocol === 'https:';
  const makeRequest = isHttps ? httpsRequest : httpRequest;

  function buildHeaders(
    req: IncomingMessage,
    bodyLength: number,
    token: NamedToken,
  ): Record<string, string | number | string[] | undefined> {
    const headers: Record<string, string | number | string[] | undefined> = {
      ...(req.headers as Record<string, string>),
      host: upstreamUrl.host,
      'content-length': bodyLength,
    };

    // Strip hop-by-hop headers that must not be forwarded by proxies
    delete headers['connection'];
    delete headers['keep-alive'];
    delete headers['transfer-encoding'];

    if (authMode === 'api-key') {
      // API key mode: inject x-api-key on every request
      delete headers['x-api-key'];
      headers['x-api-key'] = secrets.ANTHROPIC_API_KEY;
    } else {
      // OAuth mode: replace placeholder Bearer token with the real one
      // only when the container actually sends an Authorization header
      // (exchange request + auth probes). Post-exchange requests use
      // x-api-key only, so they pass through without token injection.
      if (headers['authorization']) {
        delete headers['authorization'];
        headers['authorization'] = `Bearer ${token.token}`;
      }
    }

    return headers;
  }

  return new Promise((resolve, reject) => {
    const server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', async () => {
        const body = Buffer.concat(chunks);
        const hasAuth = !!req.headers['authorization'];

        // For non-OAuth or requests without auth headers, single attempt
        if (authMode !== 'oauth' || !hasAuth || tokenPool.length <= 1) {
          const token = tokenPool[currentTokenIdx] || primaryEntry;
          const headers = buildHeaders(req, body.length, token);
          const upstream = makeRequest(
            {
              hostname: upstreamUrl.hostname,
              port: upstreamUrl.port || (isHttps ? 443 : 80),
              path: req.url,
              method: req.method,
              headers,
            } as RequestOptions,
            (upRes) => {
              res.writeHead(upRes.statusCode!, upRes.headers);
              upRes.pipe(res);
            },
          );
          upstream.on('error', (err) => {
            logger.error({ err, url: req.url }, 'Credential proxy upstream error');
            if (!res.headersSent) {
              res.writeHead(502);
              res.end('Bad Gateway');
            }
          });
          upstream.write(body);
          upstream.end();
          return;
        }

        // OAuth with multiple tokens: try current, cycle on 429/401
        const startIdx = currentTokenIdx;
        let tried = 0;

        while (tried < tokenPool.length) {
          const token = tokenPool[currentTokenIdx];
          const headers = buildHeaders(req, body.length, token);

          try {
            const result = await proxyRequest(
              {
                hostname: upstreamUrl.hostname,
                port: upstreamUrl.port || (isHttps ? 443 : 80),
                path: req.url,
                method: req.method,
                headers,
              } as RequestOptions,
              body,
              makeRequest,
            );

            if (
              (result.status === 429 || result.status === 401) &&
              tried < tokenPool.length - 1
            ) {
              // Cycle to next token
              const prevName = tokenPool[currentTokenIdx].name;
              currentTokenIdx = (currentTokenIdx + 1) % tokenPool.length;
              const nextName = tokenPool[currentTokenIdx].name;
              logger.warn(
                {
                  status: result.status,
                  from: prevName,
                  to: nextName,
                  url: req.url,
                },
                'Rate limited or auth failed, cycling token',
              );
              tried++;
              continue;
            }

            // Either success, or exhausted all tokens — return whatever we got
            if (currentTokenIdx !== startIdx) {
              logger.info(
                { activeToken: tokenPool[currentTokenIdx].name },
                'Token cycled successfully',
              );
            }
            res.writeHead(result.status, result.headers);
            res.end(result.body);
            return;
          } catch (err) {
            logger.error({ err, url: req.url }, 'Credential proxy upstream error');
            if (!res.headersSent) {
              res.writeHead(502);
              res.end('Bad Gateway');
            }
            return;
          }
        }
      });
    });

    server.listen(port, host, () => {
      logger.info({ port, host, authMode }, 'Credential proxy started');
      resolve(server);
    });

    server.on('error', reject);
  });
}

/** Detect which auth mode the host is configured for. */
export function detectAuthMode(): AuthMode {
  const secrets = readEnvFile(['ANTHROPIC_API_KEY']);
  return secrets.ANTHROPIC_API_KEY ? 'api-key' : 'oauth';
}
