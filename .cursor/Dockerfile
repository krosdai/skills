# Cloud Agent base image for the skills repository.
#
# The repo requires Node >= 24 (package.json "engines"); Cursor's default image
# ships Node 22, so we pin Node 24 here. Corepack provides the pinned pnpm
# (package.json "packageManager"), and mise provides the pinned AutoCorrect
# release declared in mise.toml. git + git-lfs are needed for checkout and the
# repository's git hooks.
FROM node:24-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        git-lfs \
    && git lfs install --system \
    && rm -rf /var/lib/apt/lists/*

# pnpm is resolved by Corepack from package.json "packageManager".
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable

# mise manages tool versions declared in mise.toml (AutoCorrect). Install the
# binary to a shared location so every user and shell can invoke it.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && mise --version

USER node
