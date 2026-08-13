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
# download. The binary is selected per host architecture (amd64/arm64) so the
# image works regardless of build platform. Update MISE_VERSION and both
# checksums together (published in the release's SHASUMS256.txt).
ARG MISE_VERSION=v2026.8.5
ARG MISE_SHA256_X64=ee362b6d96c648e27325a8bc7ee866bde4fffc20c88c777c5eb5c3b5c6f3e226
ARG MISE_SHA256_ARM64=d2bde76b1f87ab50b6f456e05332bb02de56a6bf3c5d19343cc3661e5d294681
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) mise_arch=x64; mise_sha256="${MISE_SHA256_X64}" ;; \
        arm64) mise_arch=arm64; mise_sha256="${MISE_SHA256_ARM64}" ;; \
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${mise_arch}" -o /usr/local/bin/mise; \
    echo "${mise_sha256}  /usr/local/bin/mise" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/mise; \
    mise --version

USER node
