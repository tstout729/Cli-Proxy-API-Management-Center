# Quota ledger and weekly-reset routing

Requested October 2, 2026 (Pacific): fork and install CLI Proxy API with a console matching the supplied dark quota-management screenshot, and prioritize accounts based on weekly limit resets.

## Acceptance criteria

- Proxy and console are forked to `tstout729` and downloaded locally.
- Default dark quota view has provider tabs, aggregate quota summaries, compact account rows, quota meters, masked identities, and refresh actions. Existing card view remains available.
- Server routing prefers eligible accounts with the earliest upcoming weekly reset, falls back on unavailable/exhausted accounts, and operates without an open browser.
- Weekly routing can be selected in the console; reset times display in America/Los_Angeles.
- Codex OAuth uses the upstream WebSocket path by default; explicit transport opt-outs remain supported.
- Session affinity is enabled for the local installation: a new thread uses weekly-reset priority, and later prompts retain its account for prompt-cache reuse. Exhaustion/unavailability allows safe failover.
- Meaningful routing/model tests, console verification, backend compile/tests, and desktop/mobile browser checks pass.
- Feature commits are pushed and integrated into development branches; local installation serves the built console.

## Dependencies and evidence

- Upstream proxy: `router-for-me/CLIProxyAPI`, initial commit `2044a01f`.
- Upstream console: `router-for-me/Cli-Proxy-API-Management-Center`, initial commit `752e0ee`.
- Both forks created and isolated feature worktrees prepared.
- Backend quota/routing and console implementation completed and integrated.
- Provider authentication is entered by the user at runtime. Verification uses synthetic accounts and never copies existing account credentials.
- Existing Homebrew CLI Proxy v7.2.65 remains on 127.0.0.1:8317. The custom v8 installation uses 127.0.0.1:8318 with separate configuration.

## Verification

- Console: `bun run verify` passed, 1,504 tests / 13,681 assertions, ESLint, TypeScript and single-file production build. Tested with installed Bun 1.3.11; repository package-manager pin remains 1.3.14.
- Headless Chromium: authenticated connection, quota refresh, 409% / 500% and 17% / 300% aggregates with synthetic accounts, masked/revealed identities, ledger/cards switching, 390px mobile layout without page overflow, and no runtime exceptions passed.
- Pacific tests cover UTC calendar-date conversion and 23/25-hour DST days; quota cards and timeline use Pacific calendar boundaries.
- Backend full Go suite, focused race tests and required server build passed. Tests exercise earliest weekly reset, short/model-scoped exhaustion, stale data, lower-priority fallback, same-thread model switches, request failure, WebSocket defaults, opt-outs and upgrade fallback.
- Custom local launchd service installed at 127.0.0.1:8318. Authenticated v8 API readback confirms weekly-reset-first, enabled affinity/subagent inheritance, sliding 168h affinity TTL, and Codex upstream WebSockets. Management API requires authentication; generated config/keys are mode 0600. Served panel matches the built single-file artifact.
- The isolated installation has no provider accounts yet. Provider sign-in is an explicit user setup step; upstream paid inference/cache hit rates have not been tested with real accounts.
- Timestamped video notes and M1 Pro proxy-only / daily-Mac coding setup guide saved to `~/Downloads/cli-proxy-video-notes/SETUP.txt`, with desktop/mobile previews and a `codex-proxy.sh` launcher. The launcher loads its custom Responses provider settings with installed Codex 0.160.0; it reads the separate proxy inference key without changing global Codex settings. SSH/Tailscale settings on the M1 Pro require following that guide. A future Linux coding machine can use the same gateway.

## Delivery evidence and remaining setup

- Backend feature `0ed3955c` and integration `d0bf15203fb5c08024916eb13c249e72bf7269bc` pushed to the fork. Console feature `3f0dc80` and integration `c98877175ede262e48c46355b38edc2cf0918c6d` pushed; later documentation updates do not change the verified app tree.
- Combined canonical checkouts passed the full Go suite/server build and console `bun run verify` after their serial merges.
- Reinstalled the clean integrated source. Running service reports backend commit `d0bf15203fb5c08024916eb13c249e72bf7269bc`; static panel SHA256 is `6bd5cb440d6aa1b6db901cf02a778a3e40b2586ff9eb771f25b659641eed6ef8` and matches the built console.
- Installed single-file console passed headless authenticated login and persisted round-robin → weekly-reset-first selection. Final authenticated API readback confirms the intended settings. Anonymous config access returns 401. Both loopback services still listen separately.
- Development and local installation criteria are satisfied. User setup remains: sign in to provider accounts, verify real inference/cache hit rates, and follow the M1 Pro SSH/Tailscale guide. Bindings and quota observations are in memory and reset when the service restarts. No shared schema/database changes or production-main release.
