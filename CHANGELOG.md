# Changelog — omp-hosted

## 2026.11.25 — upstream bump v18.16.0 → v19.2.1

- `OMP_UPSTREAM_REF` v18.16.0 → v19.2.1 (David GO 2026-11-25 19:40 CST).
  Upstream delta: 6461 commits, 300 files. Notable: package renamed
  `@mariozechner/pi-coding-agent` → `@oh-my-pi/pi-coding-agent`; bun base
  1.4.4 → 1.4.5 (baked by upstream base image, no image-side change);
  browser-relay `gen:embedded` added to upstream's own build (runs inside
  the base build, not ours); `/usr/local/bin/omp` entrypoint + `omp` CLI
  name unchanged. Our layers (ttyd/tmux/node/auth-proxy/cont-init/entrypoint)
  untouched by upstream diffs; models.yml + config.yml schemas unchanged.
- Version `2026.11.25`; image tag `2026.11.25.<HHMM>` on merge to main.
- Pool refresh after CI green + smoke: update OMP_IMAGE secret, drain/rebuild.

## 2026.11.06 — post-Stage-2 fixes

- smoke-retry fix: Resolve-image step retries `gh run download` 12×/10s
  (GitHub artifact availability is eventually consistent — smoke run
  42136886623 failed 4s after build completion). Fail-closed retained.
- D1 role map: advisor now pinned `→ cig/<smol>` (cheap). Upstream verified
  (v18.17.0 model-resolver.ts): UNSET advisor falls back to the configured
  `slow` role (strongest) — pinning to smol honors D1 and avoids token
  multiplication on the strongest model. vision stays UNSET (upstream vision
  fallback chain cannot match the cig/* roster → genuinely off).

## 2026.11.05 — v0.1.0 (Phase 0 scaffold)

Initial scaffold per SOP-048 Phase 0 (Stage-1 plan approved 2026-11-04 22:39 CDT).

- Dockerfile: FROM the pinned upstream pi-runtime (v18.16.0, built by CI
  from the cloned ref); ttyd + tmux + agent user (uid 10000) layers.
- entrypoint.sh: PID-1 supervisor (hermes-hosted v8 contract, adapted) —
  forensics, HOME + /data writability chains, setpriv drop probe with
  DEGRADED-ROOT fallback, cont-init, service supervision with backoff.
- cont-init.d/01-installomp-config.sh: headless models.yml (cig provider →
  loopback adapter) + config.yml (D1 role map) + workspace AGENTS.md.
- bin/omp-session: tmux-backed session persistence + ttyd foreground exec.
- auth-proxy + cig-adapter: reused from hermes-hosted (auth-proxy retargets
  OPENCLAW_INTERNAL_PORT=7681 → ttyd; BRAND_* skin).
- CI: docker-build.yml (pinned upstream clone → build → GHCR) +
  smoke-boot.yml (Fred parity: noexec /run, seccomp, 10-min liveness,
  per-service asserts, loopback invariant, regression greps).
