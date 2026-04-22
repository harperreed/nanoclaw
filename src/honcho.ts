// ABOUTME: Honcho cloud memory integration — reasoning-based cross-session user modeling.
// ABOUTME: Provides context injection before prompts and message sync after responses.

import { Honcho, Peer, Session, type MessageInput } from '@honcho-ai/sdk';
import { readEnvFile } from './env.js';
import { logger } from './logger.js';

let honcho: Honcho | null = null;
let harperPeer: Peer | null = null;

// Lazy caches — populated on demand per group
const aiPeers = new Map<string, Peer>();
const sessions = new Map<string, Session>();

// Context cache with hybrid TTL: refresh after N turns OR time elapsed
interface CachedContext {
  text: string;
  turns: number;
  timestamp: number;
}
const contextCache = new Map<string, CachedContext>();

const CONTEXT_MAX_TURNS = 3;
const CONTEXT_MAX_AGE_MS = 2 * 60 * 60 * 1000; // 2 hours

/**
 * Initialize the Honcho client and warm the Harper peer cache.
 * Returns true if Honcho is available, false otherwise.
 * Non-blocking — failures are logged and swallowed.
 */
export async function initHoncho(): Promise<boolean> {
  try {
    const env = readEnvFile(['HONCHO_API_KEY']);
    const apiKey = process.env.HONCHO_API_KEY || env.HONCHO_API_KEY;
    if (!apiKey) {
      logger.info('Honcho: no API key found, skipping initialization');
      return false;
    }

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10_000);

    try {
      honcho = new Honcho({ apiKey, workspaceId: 'nanoclaw' });
      harperPeer = await honcho.peer('harper');
      logger.info('Honcho initialized');
      return true;
    } finally {
      clearTimeout(timeout);
    }
  } catch (err) {
    logger.warn(
      { err },
      'Honcho initialization failed — continuing without memory',
    );
    honcho = null;
    harperPeer = null;
    return false;
  }
}

/**
 * Get or create an AI peer for a group.
 */
async function getAiPeer(groupFolder: string): Promise<Peer> {
  let peer = aiPeers.get(groupFolder);
  if (!peer) {
    peer = await honcho!.peer(groupFolder);
    aiPeers.set(groupFolder, peer);
  }
  return peer;
}

/**
 * Get or create a Honcho session for a group.
 */
async function getSession(groupFolder: string): Promise<Session> {
  let session = sessions.get(groupFolder);
  if (!session) {
    session = await honcho!.session(groupFolder);
    await session.addPeers([harperPeer!, await getAiPeer(groupFolder)]);
    sessions.set(groupFolder, session);
  }
  return session;
}

/**
 * Retrieve cross-session context about the user for a group.
 * Returns formatted XML string or empty string on failure/unavailability.
 * Uses AbortController with 2s timeout. Caches with hybrid TTL.
 */
export async function getHonchoContext(groupFolder: string): Promise<string> {
  if (!honcho || !harperPeer) return '';

  // Check cache — refresh when turns >= 3 OR age > 2 hours
  const cached = contextCache.get(groupFolder);
  if (cached) {
    const age = Date.now() - cached.timestamp;
    if (cached.turns < CONTEXT_MAX_TURNS && age < CONTEXT_MAX_AGE_MS) {
      return cached.text;
    }
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2_000);

  try {
    // Ensure session exists (creates peers + session if needed)
    await getSession(groupFolder);

    const representation = await harperPeer.representation();

    clearTimeout(timeout);

    if (!representation) {
      contextCache.set(groupFolder, {
        text: '',
        turns: 0,
        timestamp: Date.now(),
      });
      return '';
    }

    const text = `<honcho-context>\n[External memory — cross-session context about the user]\n${representation}\n</honcho-context>`;
    contextCache.set(groupFolder, { text, turns: 0, timestamp: Date.now() });
    return text;
  } catch (err) {
    clearTimeout(timeout);
    logger.warn({ err, groupFolder }, 'Honcho context retrieval failed');
    return '';
  }
}

/**
 * Sync messages to Honcho after an agent response.
 * Fire-and-forget — never blocks the caller.
 * Skips scheduled tasks to avoid polluting the user model with automated noise.
 */
export function syncHonchoMessages(
  groupFolder: string,
  userMessages: Array<{ content: string; sender: string }>,
  botResponse: string,
  isScheduledTask?: boolean,
): void {
  if (!honcho || !harperPeer) return;
  if (isScheduledTask) return;

  const doSync = async () => {
    const session = await getSession(groupFolder);
    const aiPeer = await getAiPeer(groupFolder);

    const messages: MessageInput[] = [
      ...userMessages.map((m) => harperPeer!.message(m.content)),
      aiPeer.message(botResponse),
    ];

    await session.addMessages(messages);

    // Increment turn counter for context cache TTL
    const cached = contextCache.get(groupFolder);
    if (cached) {
      cached.turns += userMessages.length;
    }
  };

  doSync().catch((err) =>
    logger.warn({ err, groupFolder }, 'Honcho sync failed'),
  );
}
