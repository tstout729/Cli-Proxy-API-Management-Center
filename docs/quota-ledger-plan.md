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
- Backend quota/routing contract inspection in progress; console implementation in progress.
- Provider authentication is entered by the user at runtime. Verification uses synthetic accounts and never copies existing account credentials.
- Existing Homebrew CLI Proxy v7.2.65 listens on 127.0.0.1:8317. The custom v8 installation will use 127.0.0.1:8318 with separate configuration.

## Verification

- Console: `bun run verify` passed, 1,504 tests / 13,681 assertions, ESLint, TypeScript and single-file production build. Tested with installed Bun 1.3.11; repository package-manager pin remains 1.3.14.
- Headless Chromium: authenticated connection, quota refresh, 409% / 500% and 17% / 300% aggregates with synthetic accounts, masked/revealed identities, ledger/cards switching, 390px mobile layout without page overflow, and no runtime exceptions passed.
- Pacific tests cover UTC calendar-date conversion and 23/25-hour DST days; quota cards and timeline use Pacific calendar boundaries.
- Backend full Go suite, focused race tests and required server build passed. Tests exercise earliest weekly reset, short/model-scoped exhaustion, stale data, lower-priority fallback, same-thread model switches, request failure, WebSocket defaults, opt-outs and upgrade fallback.
- Custom local launchd service installed at 127.0.0.1:8318. Authenticated v8 API readback confirms weekly-reset-first, enabled affinity/subagent inheritance, sliding 168h affinity TTL, and Codex upstream WebSockets. Management API requires authentication; generated config/keys are mode 0600. Served panel matches the built single-file artifact.
- The isolated installation has no provider accounts yet. Provider sign-in is an explicit user setup step; upstream paid inference/cache hit rates have not been tested with real accounts.
- Timestamped video notes and M1 Pro proxy-only / daily-Mac coding setup guide saved locally. SSH/Tailscale settings on the M1 Pro require following that guide.

## Remaining delivery work

Commit and push the verified feature branches, integrate into development branches, then reinstall the clean integrated source and confirm the final artifact. No shared schema or database changes.
