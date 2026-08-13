# Cloud Agent base image for the skills repository.
#
# The repo requires Node >= 24 (package.json "engines"); Cursor's default image
# ships Node 22, so we pin Node 24 here. Corepack provides the pinned pnpm
# (package.json "packageManager"), and mise provides the pinned AutoCorrect
# release declared in mise.toml. git + git-lfs are needed for checkout and the
# repository's git hooks.
FROM node:24-bookworm-slim

# System packages: git + LFS for checkout and the repo's git hooks,
# curl/ca-certificates for downloading mise, and sudo so the agent can install
# extra packages at runtime (Cursor Cloud Agents commonly rely on passwordless
# sudo, which the default image provides).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        git-lfs \
        sudo \
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/*

# Grant the unprivileged runtime user passwordless sudo.
RUN echo "node ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node

# pnpm is resolved by Corepack from package.json "packageManager".
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable

# mise manages tool versions declared in mise.toml (AutoCorrect). Pin a specific
# release and verify its SHA-256 checksum rather than piping a network-fetched
# installer into a shell, so the build fails closed on tampering or a truncated
# download. Update MISE_VERSION/MISE_SHA256 together (checksums are published in
# the release's SHASUMS256.txt).
ARG MISE_VERSION=v2026.8.5
ARG MISE_SHA256=ee362b6d96c648e27325a8bc7ee866bde4fffc20c88c777c5eb5c3b5c6f3e226
RUN curl -fsSL "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-x64" -o /usr/local/bin/mise \
    && echo "${MISE_SHA256}  /usr/local/bin/mise" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/mise \
    && mise --version

USER node
