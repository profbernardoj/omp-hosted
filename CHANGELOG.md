# Changelog — omp-hosted

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
