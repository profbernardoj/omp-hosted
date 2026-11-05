# syntax=docker/dockerfile:1

# =============================================================================
# omp-hosted — InstallOMP.ai container image
#
# The REAL can1357/oh-my-pi coding agent, hosted on Manifest Network leases,
# fronted by our Privy auth-proxy over a ttyd web terminal, powered by
# Morpheus inference via CIG.
#
# Base: upstream pi-runtime BUILT AT A PINNED GIT REF. The upstream publishes
# no registry image (workflows: ci.yml / nix.yml / bun-cache-warm.yml only —
# verified 2026-11-04), so CI clones oh-my-pi at OMP_UPSTREAM_REF, builds its
# pi-runtime stage as a local tag, and this Dockerfile consumes it via
# ARG OMP_UPSTREAM. Pin: v18.16.0 (released 2026-11-02).
#
# Layers added on top of the upstream image:
#   1. web terminal — ttyd (loopback :7681) serving `tmux attach` to a
#                     persistent omp TUI session (reconnect = same session).
#   2. auth-proxy   — Privy JWT auth + dynamic ownership + SSO handoff
#                     (everclaw auth-proxy, unmodified): ingress :18789 →
#                     upstream 127.0.0.1:7681 (ttyd). Websocket Origin
#                     rewriting per the hermes v9.3.2 lesson.
#   3. cig-adapter  — loopback OpenAI-compatible shim on :18900. omp's
#                     models.yml custom provider (api: openai-completions)
#                     hits it with a static local key; it mints short-lived
#                     CIG tokens (binding_secret) and forwards to
#                     cig-inference → Morpheus. No master key in the container.
#   4. entrypoint   — PID-1 supervisor (hermes-hosted v8 contract, adapted):
#                     runs cont-init from the image layer, starts services
#                     privilege-dropped via setpriv, supervises with backoff.
#                     NOTHING EXECUTES FROM /run (Fred tenant sandbox).
#
# SOP-004 hard rules: built by GitHub Actions → GHCR only; amd64; NEVER
# built locally on the Mac mini.
# =============================================================================

ARG OMP_UPSTREAM=oh-my-pi/pi:v18.16.0
FROM ${OMP_UPSTREAM}

# --- Metadata ---
LABEL org.opencontainers.image.title="omp-hosted"
LABEL org.opencontainers.image.description="Hosted OMP coding agent (InstallOMP.ai) — ttyd web terminal + Privy auth + Morpheus CIG inference"
LABEL org.opencontainers.image.source="https://github.com/profbernardoj/omp-hosted"
LABEL io.installomp.base-image="can1357/oh-my-pi:v18.16.0 (pi-runtime, built from pinned ref)"

# --- Our layer: web terminal + privilege-drop tooling ---
# ttyd + tmux: the web terminal surface. util-linux provides setpriv
# (privilege drops without s6). procps for pgrep-driven supervision helpers.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ttyd tmux util-linux procps \
    && rm -rf /var/lib/apt/lists/*

# --- Agent user (uid 10000; the Fred manifest user target) ---
RUN useradd --create-home --uid 10000 --shell /bin/bash agent \
    && mkdir -p /home/agent/workspace \
    && chown -R 10000:10000 /home/agent

# --- Our services ---
COPY cig-adapter/server.mjs /usr/local/lib/installomp/cig-adapter/server.mjs
COPY auth-proxy/server.mjs /usr/local/lib/installomp/auth-proxy/server.mjs
COPY auth-proxy/egress-probes.mjs /usr/local/lib/installomp/auth-proxy/egress-probes.mjs
COPY auth-proxy/login.html /usr/local/lib/installomp/auth-proxy/login.html
COPY auth-proxy/login-app.jsx /usr/local/lib/installomp/auth-proxy/login-app.jsx
COPY auth-proxy/build-login.mjs /usr/local/lib/installomp/auth-proxy/build-login.mjs
COPY auth-proxy/package.json /usr/local/lib/installomp/auth-proxy/package.json
COPY auth-proxy/package-lock.json /usr/local/lib/installomp/auth-proxy/package-lock.json
COPY auth-proxy/assets/ /usr/local/lib/installomp/auth-proxy/assets/

# --- Auth-proxy: deps + LOGIN BUNDLE BUILD (hermes-hosted pattern) ---
# The login page is a BUILD ARTIFACT: build-login.mjs (esbuild) bundles
# login-app.jsx + React + the Privy SDK into dist/login-bundle.js, which
# server.mjs loads at boot. Without it the auth-proxy exits (ENOENT) and
# crash-loops (hermes v6 lesson).
RUN cd /usr/local/lib/installomp/auth-proxy && \
    npm ci --ignore-scripts --no-audit --no-fund && \
    npm run build && \
    rm -rf node_modules && \
    npm ci --omit=dev --no-audit --no-fund && \
    npm cache clean --force

# --- Launchers + supervisor + cont-init ---
COPY bin/cig-adapter /usr/local/bin/cig-adapter
COPY bin/auth-proxy /usr/local/bin/auth-proxy
COPY bin/omp-session /usr/local/bin/omp-session
COPY entrypoint.sh /usr/local/bin/installomp-entrypoint
COPY cont-init.d/01-installomp-config.sh /etc/cont-init.d/01-installomp-config.sh
RUN chmod +x /usr/local/bin/cig-adapter /usr/local/bin/auth-proxy \
    /usr/local/bin/omp-session /usr/local/bin/installomp-entrypoint \
    /etc/cont-init.d/01-installomp-config.sh

# --- Defaults (manifest-overridable; product invariants enforced at boot) ---
ENV BRAND_NAME="OMP" \
    BRAND_ICON="⌥" \
    BRAND_TAGLINE="Your coding agent. Hosted. Your inference." \
    AUTH_PROXY_PORT=18789 \
    OPENCLAW_INTERNAL_PORT=7681 \
    TTYD_HOST=127.0.0.1 \
    TTYD_PORT=7681 \
    CIG_ADAPTER_PORT=18900 \
    OMP_WORKSPACE=/home/agent/workspace \
    OMP_MODEL_DEFAULT=glm-5.2 \
    OMP_MODEL_SLOW=deepseek-v4-pro \
    OMP_MODEL_SMOL=deepseek-v4-flash-0731 \
    OMP_MODELS_EXTRA="" \
    AGENT_UID=10000

# Our supervisor is PID 1. The upstream tini+omp ENTRYPOINT is replaced:
# the omp TUI runs INSIDE the tmux session, not as the main program.
ENTRYPOINT ["/usr/local/bin/installomp-entrypoint"]
