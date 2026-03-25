/**
 * Container runtime abstraction for NanoClaw.
 * All runtime-specific logic lives here so swapping runtimes means changing one file.
 */
import { execSync } from 'child_process';
import fs from 'fs';
import os from 'os';

import { logger } from './logger.js';

/** The container runtime binary name. */
export const CONTAINER_RUNTIME_BIN = 'container';

/**
 * Hostname or IP containers use to reach the host machine.
 * Docker Desktop (macOS/Windows): host.docker.internal is built-in.
 * Apple Container (macOS): uses a vmnet bridge — detect the gateway IP.
 * Linux: host.docker.internal is added via --add-host in hostGatewayArgs().
 */
export const CONTAINER_HOST_GATEWAY = detectHostGateway();

function detectHostGateway(): string {
  // Apple Container on macOS: host.docker.internal doesn't exist.
  // The container VM sits on a bridge (bridge100+) with a 192.168.64.x subnet.
  // Detect the host's IP on that bridge so containers can reach the proxy.
  if (os.platform() === 'darwin' && CONTAINER_RUNTIME_BIN === 'container') {
    const bridgeIp = findBridgeIp();
    if (bridgeIp) return bridgeIp;
  }
  return 'host.docker.internal';
}

/**
 * Find the host IP on Apple Container's vmnet bridge interface.
 * Apple Container creates bridge100+ with a 192.168.64.0/24 subnet.
 */
function findBridgeIp(): string | null {
  const ifaces = os.networkInterfaces();
  for (const [name, addrs] of Object.entries(ifaces)) {
    if (!name.startsWith('bridge') || !addrs) continue;
    const ipv4 = addrs.find(
      (a) => a.family === 'IPv4' && a.address.startsWith('192.168.64.'),
    );
    if (ipv4) return ipv4.address;
  }
  return null;
}

/**
 * Address the OneCLI gateway or credential proxy binds to.
 * Docker Desktop (macOS): 127.0.0.1 — the VM routes host.docker.internal to loopback.
 * Apple Container (macOS): bind to the bridge IP so containers can reach it.
 * Docker (Linux): bind to the docker0 bridge IP so only containers can reach it,
 *   falling back to 0.0.0.0 if the interface isn't found.
 */
export const PROXY_BIND_HOST =
  process.env.CREDENTIAL_PROXY_HOST || detectProxyBindHost();

function detectProxyBindHost(): string {
  if (os.platform() === 'darwin') {
    // Apple Container: must listen on the bridge IP, not loopback
    if (CONTAINER_RUNTIME_BIN === 'container') {
      return findBridgeIp() || '0.0.0.0';
    }
    // Docker Desktop: loopback is correct (VM routes host.docker.internal there)
    return '127.0.0.1';
  }

  // WSL uses Docker Desktop (same VM routing as macOS) — loopback is correct.
  // Check /proc filesystem, not env vars — WSL_DISTRO_NAME isn't set under systemd.
  if (fs.existsSync('/proc/sys/fs/binfmt_misc/WSLInterop')) return '127.0.0.1';

  // Bare-metal Linux: bind to the docker0 bridge IP instead of 0.0.0.0
  const ifaces = os.networkInterfaces();
  const docker0 = ifaces['docker0'];
  if (docker0) {
    const ipv4 = docker0.find((a) => a.family === 'IPv4');
    if (ipv4) return ipv4.address;
  }
  return '0.0.0.0';
}

/** CLI args needed for the container to resolve the host gateway. */
export function hostGatewayArgs(): string[] {
  // On Linux, host.docker.internal isn't built-in — add it explicitly
  if (os.platform() === 'linux') {
    return ['--add-host=host.docker.internal:host-gateway'];
  }
  return [];
}

/** Returns CLI args for a readonly bind mount. */
export function readonlyMountArgs(
  hostPath: string,
  containerPath: string,
): string[] {
  return [
    '--mount',
    `type=bind,source=${hostPath},target=${containerPath},readonly`,
  ];
}

/** Returns the shell command to stop a container by name. */
export function stopContainer(name: string): string {
  return `${CONTAINER_RUNTIME_BIN} stop -t 1 ${name}`;
}

/** Ensure the container runtime is running, starting it if needed. */
export function ensureContainerRuntimeRunning(): void {
  try {
    execSync(`${CONTAINER_RUNTIME_BIN} system status`, { stdio: 'pipe' });
    logger.debug('Container runtime already running');
  } catch {
    logger.info('Starting container runtime...');
    try {
      execSync(`${CONTAINER_RUNTIME_BIN} system start`, {
        stdio: 'pipe',
        timeout: 30000,
      });
      logger.info('Container runtime started');
    } catch (err) {
      logger.error({ err }, 'Failed to start container runtime');
      console.error(
        '\n╔════════════════════════════════════════════════════════════════╗',
      );
      console.error(
        '║  FATAL: Container runtime failed to start                      ║',
      );
      console.error(
        '║                                                                ║',
      );
      console.error(
        '║  Agents cannot run without a container runtime. To fix:        ║',
      );
      console.error(
        '║  1. Ensure Apple Container is installed                        ║',
      );
      console.error(
        '║  2. Run: container system start                                ║',
      );
      console.error(
        '║  3. Restart NanoClaw                                           ║',
      );
      console.error(
        '╚════════════════════════════════════════════════════════════════╝\n',
      );
      throw new Error('Container runtime is required but failed to start', {
        cause: err,
      });
    }
  }
}

/** Returns the shell command to remove a stopped container by name. */
export function removeContainer(name: string): string {
  return `${CONTAINER_RUNTIME_BIN} delete ${name}`;
}

/** Stop running and remove stopped NanoClaw containers from previous runs. */
export function cleanupOrphans(): void {
  try {
    const output = execSync(`${CONTAINER_RUNTIME_BIN} ls --format json`, {
      stdio: ['pipe', 'pipe', 'pipe'],
      encoding: 'utf-8',
    });
    const containers: { status: string; configuration: { id: string } }[] =
      JSON.parse(output || '[]');
    const nanoclaw = containers.filter((c) =>
      c.configuration.id.startsWith('nanoclaw-'),
    );

    const running = nanoclaw
      .filter((c) => c.status === 'running')
      .map((c) => c.configuration.id);
    for (const name of running) {
      try {
        execSync(stopContainer(name), { stdio: 'pipe' });
      } catch {
        /* already stopped */
      }
    }

    // Remove all stopped nanoclaw containers (including ones just stopped above)
    const stopped = nanoclaw.map((c) => c.configuration.id);
    for (const name of stopped) {
      try {
        execSync(removeContainer(name), { stdio: 'pipe' });
      } catch {
        /* already removed */
      }
    }

    if (running.length > 0 || stopped.length > 0) {
      logger.info(
        { stopped: running.length, removed: stopped.length },
        'Cleaned up orphaned containers',
      );
    }
  } catch (err) {
    logger.warn({ err }, 'Failed to clean up orphaned containers');
  }
}
