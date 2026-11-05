# omp-hosted

**Hosted OMP coding agent (InstallOMP.ai)** — the real
[`can1357/oh-my-pi`](https://github.com/can1357/oh-my-pi) running as a
Manifest Network container, fronted by our Privy auth-proxy over a **ttyd
web terminal**, powered by Morpheus inference via CIG.

Built per **SOP-048** (Adding a New Agentic Harness — Hosted Vertical);
machinery per SOP-045. Stage-1 plan: `memory/projects/installomp/`.

## Architecture

```
Internet → auth-proxy :18789 (Privy JWT, dynamic ownership, SSO handoff)
              └→ ttyd :7681 (loopback) → tmux session `omp` → omp TUI
cig-adapter :18900 (loopback) ← omp models.yml custom provider
              └→ mint-cig-token (binding_secret) → cig-inference → Morpheus
```

- **PID-1 supervisor** (`entrypoint.sh`): cont-init → services → supervise
  with backoff. Nothing executes from `/run` (Fred tenant sandbox).
- **Session persistence**: the omp TUI runs inside a tmux session; ttyd
  serves `tmux attach`. Browser reconnects and ttyd crashes land on the
  same live session.
- **Product invariants** (re-asserted at boot): ttyd and cig-adapter bind
  loopback ONLY; the auth-proxy is the only ingress.

## Base image

The upstream publishes no registry image (verified 2026-11-04). CI clones
`can1357/oh-my-pi` at `OMP_UPSTREAM_REF` (**v18.16.0**, released
2026-11-02), builds its `pi-runtime` stage as a local tag, and this
Dockerfile consumes it via `ARG OMP_UPSTREAM`. Bump the pin via the
SOP-005-style procedure; the build logs the resolved upstream commit sha.

## Container environment contract

Set by the provision-buffer / deploy-agent manifests (Phase 2 wires
`_shared/vertical-constants.ts`):

| Env | Default | Purpose |
|-----|---------|---------|
| `AUTH_PROXY_PORT` | 18789 | auth-proxy ingress port |
| `OPENCLAW_INTERNAL_PORT` | 7681 | auth-proxy → ttyd retarget |
| `TTYD_HOST` / `TTYD_PORT` | 127.0.0.1 / 7681 | web terminal (loopback INVARIANT) |
| `CIG_ADAPTER_PORT` | 18900 | cig-adapter loopback port |
| `CIG_ADAPTER_KEY` | — (required) | static local key omp → adapter |
| `CIG_MINT_URL` / `CIG_INFERENCE_URL` | — | mint-cig-token / cig-inference EF URLs |
| `CIG_BINDING_SECRET` | — | container binding secret for token mint |
| `CIG_CONTAINER_FQDN` / `CONTAINER_FQDN` | — | FQDN binding (X-Container-Fqdn) |
| `PRIVY_APP_ID` / `PRIVY_VERIFICATION_KEY` | — | the installomp vertical's Privy app |
| `VERIFY_OWNER_URL` / `VERIFY_OWNER_SECRET` | — | dynamic ownership |
| `SESSION_SECRET` / `HANDOFF_SIGNING_SECRET` + handoff URLs | — | SSO session + handoff |
| `BRAND_NAME` / `BRAND_ICON` / `BRAND_TAGLINE` | OMP / ⌥ / … | login skin |
| `AGENT_NAME` | OMP Agent | the user's agent name (AGENTS.md) |
| `OMP_MODEL_DEFAULT` / `OMP_MODEL_SLOW` / `OMP_MODEL_SMOL` | glm-5.2 / deepseek-v4-pro / deepseek-v4-flash-0731 | D1 role map |
| `OMP_MODELS_EXTRA` | (empty) | additional CIG roster model ids |
| `AGENT_UID` | 10000 | the agent user (Fred manifest user) |

## Build & smoke (CI only — SOP-004: never local Docker)

- `docker-build.yml`: clone pinned upstream → build upstream → build ours →
  push `ghcr.io/profbernardoj/omp-hosted:<calver>`.
- `smoke-boot.yml`: Fred parity — `--tmpfs /run:rw,noexec` +
  `fred-tenant-seccomp.json`, 10-minute hard-gated liveness, per-service
  assertions, loopback-bind invariant check (merge-blocking for LIVE),
  regression greps, idempotent pre-flight.

## Versioning

CalVer (`YYYY.M.DD.HHMM`), CHANGELOG.md per release. The upstream pin and
its commit sha are recorded in every build's step summary.

## Open items (tracked in the Stage-1 plan §10)

1. advisor/vision role semantics: verify UNSET disables (vs falls back to
   default) — if fallback, pin to the cheapest model in config.yml.
2. Login skin polish (login-app.jsx is the Hermes skin; brand via
   `BRAND_*` env works, dedicated OMP styling is a follow-up).
3. Registry-image check on each upstream release (if they ever publish,
   switch the CI to FROM it).
