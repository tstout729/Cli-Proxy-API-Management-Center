# AI Usage

A native macOS menu bar app showing every Claude and Codex account in the shared CLI proxy. It shows used percentages, five-hour and weekly limits, optional model limits, Pacific reset times, and reported reset credits. Login failures, exhausted limits, missing data and stale readings have separate states. It refreshes every five minutes and on demand.

The app uses Swift 6, SwiftUI, AppKit and Foundation, with no external dependencies. It requires macOS 14 or later. The menu bar item uses a chart symbol; click it to open the account panel.

## Build and test

On a Mac with full Xcode selected:

```sh
swift test
./scripts/package-app.sh
open "dist/AI Usage.app" --args --demo
```

The script builds the current architecture, packages `dist/AI Usage.app`, signs it locally and verifies the signature. It does not install the app or change proxy settings. Command Line Tools can build the app, but do not include the XCTest framework required by `swift test`.

`--demo` renders synthetic account data through the production parser and UI. It makes no network request and reads no key. CI runs the tests and packaging check on macOS.

## Connect

The default management address is `http://127.0.0.1:8318`. On Trevor's MacBook this is an encrypted connection to the single team proxy, rather than a separate account pool. The app does not manage that connection.

The management key is read at refresh time from `~/.config/cliproxyapi-custom/management-key`. It must be a regular file owned by the current user with mode `0600`. No key value goes in source, arguments, URLs or logs. Optional test overrides are `AI_USAGE_BASE_URL` and `AI_USAGE_KEY_PATH` environment variables; they do not accept a key value.

The app reads inventory from `/v8/management/credentials`, then calls the proxy's `/v8/management/requests/api-call` for each account's allowlisted usage URL. The literal `Bearer $TOKEN$` is resolved inside the proxy. Provider OAuth credentials stay on the proxy. Codex usage requests include the account ID from inventory claims when reported.

There are no reset redemption, spending, credential download, login, or provider-direct calls. Reset counts are informational. Redirects are refused, cookies and network caches are disabled, and usage data stays in memory. At most three account requests run at once; concurrent refresh requests are coalesced.

## Install and check

After the source change is merged, copy the verified bundle to `~/Applications/AI Usage.app` and launch it. Quit an older copy before replacing it. A user LaunchAgent can open it at login with `RunAtLoad`; leave `KeepAlive` off so Quit works normally.

A read-only production check is:

```sh
"$HOME/Applications/AI Usage.app/Contents/MacOS/AIUsage" --check
```

This prints provider counts and successful/failed usage-request counts only. It exits `0` on a complete refresh, `1` for connection or account errors, and `2` for invalid arguments. An account requiring login can produce exit `1` while the remaining accounts report normally. Inspect the panel to distinguish failures; no identities or raw response bodies are printed.

Missing values stay unknown. A passed reset time prompts a refresh instead of fabricating a new balance. Failed refreshes retain the previous reading and mark it stale. Codex windows use their actual duration, so a monthly window is not mislabeled weekly. Reset availability is treated as historical after a relevant boundary or stale reading.

## Verification

The synthetic Swift tests cover parsing, malformed and missing values, Pacific dates, scoped Codex account headers, actual window durations, login errors versus exhaustion, reset counts, stale retention, bounded concurrency, and private key-file handling. Use the demo to inspect the panel without exposing account identities in screenshots. Then run the live check and confirm real account states before installing a release.
