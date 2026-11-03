# Verification record

This record describes checks actually executed on 3 November 2026, on an Apple Silicon Mac running macOS 26.6.2, Xcode 26.3, and Swift 6.2.4. The deployment target is macOS 14; running on macOS 14 or Intel hardware has not been tested.

## Automatic suggestions update

The latest `swift test` run passed **82 tests, 0 failures**. This includes the 54 initial tests below and 28 additional tests:

- 14 automatic-policy/rebase tests cover exact UTF-16 and field/options fingerprints, duplicate suppression, one active review, rolling request limits, delayed retries, stale completion isolation, and retaining only safe nonoverlapping proposals after an applied edit without another API call.
- 7 live-capture policy tests cover editable evidence, rejection of read-only/secure controls, restricted Chromium accessibility activation, and minimal grapheme-safe insertion/deletion/Unicode edits.
- 7 injected asynchronous app-pipeline tests cover safe mixed-content requests, zero calls for excluded/cloud-disabled prose, late cancelled responses, old/new review isolation, cloud-off cancellation, shared budget preflight, and separate automatic/cloud preferences. No real Keychain credentials or API transport are used.

The updated native application passed Xcode Debug build, release packaging, and strict local codesign verification. The automatic UI has been inspected with its default 1.2-second pause, editable-field monitoring, per-app exclusions, and dynamic Accessibility status. Source inspection separately checked cancellation, nonactivating panel presentation, stale-field guards, settings-window resume, ignored-proposal retention, and unverified-write warnings.

Live Chrome fixture verification requires the **current** `build/Lynt.app` to have macOS Accessibility permission. Ad-hoc signing binds the permission to the exact binary signature; rebuilding can invalidate an older permission record. Select the current bundle by its full path and confirm **Accessibility: Allowed** in Lynt Settings before closing the Lynt windows and focusing the fixture. A disabled/obsolete permission must not be reported as a successful editor integration test.

For repeatable tests without provider credits, quit any running Lynt copies and launch:

```sh
open -n --stdout build/live-smoke-status.txt --stderr build/live-smoke-stderr.txt \
  build/Lynt.app --args --live-smoke-test
open -a 'Google Chrome' docs/Fixtures/editor-smoke.html
```

This explicit developer mode uses isolated preferences, an isolated Keychain service, an in-memory budget and `LiveSmokeProvider`; real API keys are not read. Suggestions are labelled **Local smoke test · no network**. Its diagnostics contain status and AX role/editability metadata only, never document text, keys, selection contents or window titles. Normal mode does not print these diagnostics. `docs/Fixtures/editor-smoke.html` contains synthetic input, textarea, plain/rich contenteditable, protected-code, non-English, password and read-only cases; its local event counters help verify that accepted native edits notify the web editor. It has no network/storage and prevents test-form navigation.

The older on-demand verification record below is retained to distinguish previously observed behavior from the newly added automatic workflow. Real model quality is still separate from UI/transport validation.

## Automated checks executed

`swift test` passed **54 tests, 0 failures**:

- **10 protection tests:** a 20-case portable JSON privacy corpus; 19 fenced language examples; 15 unfenced technical examples; mixed English/Turkish/Azerbaijani; endpoints/search operators/numbers/secrets; malformed fences/JSON; markup bodies, multiline code/SQL strings, heredocs, command islands and stack traces; exact request JSON; local NaturalLanguage results; 120 seeded Unicode/CRLF identity round trips; bounded contraction/quote handling.
- **11 suggestion tests:** all four categories, accepted-only composition, overlapping alternatives, duplicate/missing/unknown segment IDs, absent/repeated/partial-word anchors, excessive expansion, stale/forged edits, literal Unicode anchoring, protected-range survival after length changes, qualified tone and Search restrictions, non-English replacement rejection, and no Delivery rewrite under Preserve.
- **21 provider/budget tests:** default DeepSeek with one batched request, HTTP 402 credit fallback, HTTP 429/both-provider failure, timeouts/invalid/truncated/oversized/blank replies, missing or malformed provider configuration, cancellation without fallback, fallback disabled, reverse preference in the reusable adapter, no eligible prose/no calls, exact same protected-content-free prose in both provider requests, conservative budget preflight/unknown usage, atomic reservations, persistence, crash/restart and month rollover.
- **3 platform snapshot tests:** Unicode canonical equivalence cannot hide changed UTF-16 source, CRLF changes invalidate the snapshot, and missing AX attributes do not equal empty attributes. These test the exact-comparison predicate, not a live AX editor.
- **9 app-model tests:** synthetic four-category playground with no auto-acceptance; accept/ignore/undo composition; cancel clearing transient state; pending task cancellation; option and privacy invalidation; cloud-disabled review; non-English early exit even when cloud is enabled; mutually exclusive overlapping choices. These use isolated temporary preference suites and do not read real keys.

`xcodebuild -quiet -project Lynt.xcodeproj -scheme Lynt -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/XcodeDerivedData CODE_SIGNING_ALLOWED=NO build` succeeded. The Xcode application scheme has no XCTest targets; run `swift test` for the test suite.

`Scripts/build-app.sh` successfully built the release SwiftPM executable, packaged `build/Lynt.app`, and signed it locally. `codesign --verify --deep --strict build/Lynt.app` passed. `plutil -lint` validated both the checked-in Info.plist and Xcode project. The two portable contract schema files were parsed as JSON; they are documentation for the DTOs and were not validated by a separate JSON Schema engine. Runtime checks use Codable and local validation, with differences documented inside the schemas.

The raw build/test logs are local, ignored artifacts in `build/`. All source fixtures and mocked credentials are synthetic. No live provider request or provider credit was used for these checks.

## Interactive checks executed

The locally packaged application was launched and its native accessibility tree and screenshot inspected. The following were observed:

- The review window, menu-bar agent, context and tone controls open.
- Local playground shows all four textual category labels and red/blue/green/purple underlines.
- Clicking an underline opens the corresponding suggestion.
- Accepting the correctness proposal changes only that proposal in the assembled preview; the other sample proposals remain unaccepted.
- Settings exposes separate secure API key fields, DeepSeek default model/endpoint, Ministral fallback model/endpoint, enabled fallback, category controls, token limits, shortcut controls, and Accessibility actions.
- Cloud review is initially off and the Keychain entries are unconfigured. No real keys were entered.
- The final packaged manual editor preserves typed straight apostrophes and quotes in a synthetic prose/code input after disabling system substitutions. Local outgoing-request inspection shows exactly the two English sentences and excludes the TypeScript fence, synthetic private marker, and Azerbaijani sentence. Cancel returns the editor to empty state.

These are manual smoke checks, not an automated UI test suite or a complete VoiceOver/keyboard audit.

## Not yet verified

- Real DeepSeek/Ministral requests, current account access, model quality, real billing/usage accuracy, latency, or model adherence to meaning/constraints across all four categories.
- Actual credit exhaustion, rate-limit or offline behavior against provider infrastructure; these paths are tested with an injected HTTP transport.
- Real selection/capture/replacement in Safari, Chrome, ChatGPT, Claude, Notes, TextEdit, Google Docs, IDEs or rich editors. No per-application support is claimed.
- Accessibility grant/denial/revocation, secure controls in third-party apps, real field changes/focus races, editor behavior after a successful AX call, or shortcut conflicts on different keyboard layouts.
- Developer ID signing, notarization, installation/update distribution, Intel execution or older macOS runtime behavior.
- Exhaustive code/secret/language detection, semantic equivalence of model edits, or protection against every unmarked prose-shaped diagnostic/secret. The current corpus is a regression set, not a universal privacy proof.

There is no simulated paste fallback; unsupported or uncertain target writes use Copy. This avoids clipboard restoration races but does not make all editors replaceable. Whole-field writes are restricted to standard text-field/combobox roles; multiline text areas without a safe selected-text path are Copy only.

## Next live verification

1. Open the app and try the local playground. Configure API keys through Settings; inspect the outgoing payload for a synthetic English + code fixture before enabling cloud review.
2. Review synthetic sentences in each category and already-correct English. Confirm the result names DeepSeek. Use a deliberately unavailable test provider configuration to observe a labelled Ministral fallback; avoid exposing real keys or source text in reports.
3. For each intended external editor, record selected-text reading, full-field reading, whether Apply is offered, and the exact observed result after an accepted edit. Keep unsupported editors on Copy.
4. Change the original field's text/selection/window while the review is open. Apply must stop on stale state. Never use valuable unsaved content for initial write tests.
5. Turn cloud/fallback off or close/cancel during a delayed review. Confirm no later fallback or stale result is shown. Compare Unicode/CRLF strings exactly.
6. Add every discovered protection failure as a synthetic corpus fixture before changing detectors. Measure false positives and missed reviews along with leaks; a conservative skip is preferable to exposing uncertain data.

## Fixture and contract locations

- `Tests/LyntCoreTests/Fixtures/protection-corpus.json` is an array of `{id,input,forbidden,zeroSegments}`. Each case checks payload exclusion and unchanged identity composition; detailed response mapping and accepted-edit behavior are covered in the separate suggestion tests. Not every illustrative brief case has a complete standalone input/request/response/output golden record yet.
- `Contracts/review-request.schema.json` and `Contracts/review-response.schema.json` describe the portable wire format for a future Android implementation.
- The provider tests inject `HTTPTransport`; no real endpoint is contacted. Failing HTTP bodies are intentionally unavailable in user-facing error messages.
