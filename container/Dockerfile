# NanoClaw Agent Container
# Runs Claude Agent SDK in isolated Linux VM with browser automation

# Builder stage: compile Rust binaries from source (no pre-built releases)
FROM rust:slim-bookworm AS rust-builder
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
RUN cargo install --git https://github.com/graphwork/workgraph
RUN cargo install --git https://github.com/harperreed/micropub

FROM node:22-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    chromium \
    fonts-liberation \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    libgbm1 \
    libnss3 \
    libatk-bridge2.0-0 \
    libgtk-3-0 \
    libx11-xcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libasound2 \
    libpangocairo-1.0-0 \
    libcups2 \
    libdrm2 \
    libxshmfence1 \
    curl \
    git \
    jq \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# Set Chromium path for agent-browser
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

# Install mise (polyglot dev tools version manager)
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Install uv (fast Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh

# Install Python via uv to a system-wide location accessible by the node user
ENV UV_PYTHON_INSTALL_DIR=/usr/local/uv/python
RUN uv python install 3

# Copy compiled Rust binaries from builder
COPY --from=rust-builder /usr/local/cargo/bin/wg /usr/local/bin/wg
COPY --from=rust-builder /usr/local/cargo/bin/micropub /usr/local/bin/micropub

# Install Harper's tools from latest GitHub releases (fetched dynamically at build time).
# fetch <repo> <asset-pattern> [target-binary-name]  — for .tar.gz assets
RUN set -ex; \
    fetch() { \
        repo=$1; pattern=$2; name=${3:-}; \
        url=$(curl -sf "https://api.github.com/repos/${repo}/releases/latest" | \
              grep '"browser_download_url"' | grep "${pattern}" | head -1 | cut -d'"' -f4); \
        if [ -z "$url" ]; then echo "WARN: no asset matching ${pattern} for ${repo}"; return 0; fi; \
        tmpdir=$(mktemp -d); \
        curl -fsSL "$url" | tar xz -C "$tmpdir"; \
        if [ -n "$name" ]; then \
            bin=$(find "$tmpdir" -maxdepth 3 -type f | head -1); \
            [ -n "$bin" ] && install -m755 "$bin" "/usr/local/bin/${name}"; \
        else \
            find "$tmpdir" -maxdepth 3 -type f -perm /111 | \
                while read f; do install -m755 "$f" "/usr/local/bin/$(basename "$f")"; done; \
        fi; \
        rm -rf "$tmpdir"; \
    }; \
    fetch harperreed/digest      "Linux_arm64.tar.gz"; \
    fetch harperreed/bbs-mcp     "Linux_arm64.tar.gz"; \
    fetch harperreed/chronicle   "linux-arm64.tar.gz"  chronicle; \
    fetch harperreed/crm         "linux_arm64.tar.gz"  crm; \
    fetch harperreed/health      "Linux_arm64.tar.gz"; \
    fetch harperreed/memo        "Linux_arm64.tar.gz"; \
    fetch harperreed/position    "Linux_arm64.tar.gz"; \
    fetch harperreed/toki        "Linux_arm64.tar.gz"; \
    fetch 2389-research/gsuite-mcp "linux_arm64.tar.gz"; \
    fetch wesm/msgvault          "linux_arm64.tar.gz"; \
    fetch 2389-research/pulse    "Linux_arm64.tar.gz"

# Install agent-browser and claude-code globally
RUN npm install -g agent-browser @anthropic-ai/claude-code

# Create app directory
WORKDIR /app

# Copy package files first for better caching
COPY agent-runner/package*.json ./

# Install dependencies
RUN npm install

# Copy source code
COPY agent-runner/ ./

# Build TypeScript
RUN npm run build

# Create workspace directories
RUN mkdir -p /workspace/group /workspace/global /workspace/extra /workspace/ipc/messages /workspace/ipc/tasks /workspace/ipc/input

# Create entrypoint script
# Secrets are passed via stdin JSON — temp file is deleted immediately after Node reads it
# Follow-up messages arrive via IPC files in /workspace/ipc/input/
# Dangling-symlink cleanup: some tools (gsuite-mcp, msgvault) have symlinks
# to /workspace/extra/ paths that only exist when the group has additionalMounts.
# If the target doesn't exist, remove the symlink so the tool can create its
# own default config directory instead of crashing on a broken link.
RUN printf '#!/bin/bash\nset -e\nfor link in /home/node/.config/gsuite-mcp /home/node/.local/share/gsuite-mcp; do\n  [ -L "$link" ] && [ ! -e "$link" ] && rm -f "$link"\ndone\ncd /app && npx tsc --outDir /tmp/dist 2>&1 >&2\nln -s /app/node_modules /tmp/dist/node_modules\nchmod -R a-w /tmp/dist\ncat > /tmp/input.json\nnode /tmp/dist/index.js < /tmp/input.json\n' > /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# Set ownership to node user (non-root) for writable directories.
# Also chown the uv Python dir so the node user can install additional Python versions.
# Create writable XDG data dirs for tools that need them.
# gsuite-mcp and msgvault symlinks are only useful when groups mount the
# corresponding /workspace/extra/ paths — otherwise they dangle. We still
# create them so groups that DO mount those paths get the config wired up,
# but the directories under .config/ and .local/ must be writable by node
# so tools like toki, chronicle, memo can create their own config dirs.
RUN mkdir -p /home/node/.config /home/node/.local/share/bbs && \
    ln -sf /workspace/extra/.config-gsuite-mcp /home/node/.config/gsuite-mcp && \
    ln -sf /workspace/extra/.local-share-gsuite-mcp /home/node/.local/share/gsuite-mcp

RUN chown -R node:node /workspace /usr/local/uv /home/node/.config /home/node/.local && \
    chmod 777 /home/node

# Switch to non-root user (required for --dangerously-skip-permissions)
USER node

# Set working directory to group workspace
WORKDIR /workspace/group

# Entry point reads JSON from stdin, outputs JSON to stdout
ENTRYPOINT ["/app/entrypoint.sh"]
