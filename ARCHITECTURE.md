# Lynt architecture

Lynt is a native macOS 14+ writing assistant with automatic suggestions beside the focused editable field after a typing pause, plus manual shortcut/paste review. SwiftUI supplies the menu-bar application, floating suggestions, and review windows; AppKit, Accessibility, NaturalLanguage, Security, Carbon, CryptoKit and Foundation provide platform services. There are no third-party package dependencies, server, cloud account, database, telemetry, or Android implementation.

The current project is an initial usable implementation with automated core tests. It does not establish universal editor compatibility, complete detection of technical material or secrets, or real-provider writing quality. See [TESTING.md](TESTING.md) for checks actually run and remaining manual verification.

## Targets and build paths

- `Sources/LyntCore`: document and JSON contracts, ordered content protection, local language gating, provider transport/fallback, token budgets, automatic-review fingerprint/rate policy, anchored suggestions, recomposition and local rebasing.
- `Sources/LyntPlatform`: macOS focused-field monitoring/capture/replacement, Keychain credentials, and registered global shortcuts.
- `Sources/LyntApp`: SwiftUI/AppKit shell, settings, automatic-review orchestration, nonactivating floating panel, ephemeral manual review state, four-category preview, and local playground.
- `Tests/LyntCoreTests`: protection corpus, suggestion/composition tests, and mock HTTP/provider/budget tests.
- `Tests/LyntPlatformTests`: exact editor-snapshot text comparisons, including Unicode normalization and CRLF changes. These tests do not exercise live third-party editors.
- `Tests/LyntAppTests`: isolated review-state tests for explicit acceptance, overlaps, cancellation, option/privacy changes, and local-only early exits. They do not send live provider requests or exercise the actual window UI.

`Package.swift` exposes the `LyntCore` and `LyntPlatform` libraries and the `Lynt` executable. `Lynt.xcodeproj` builds a native application using the local package libraries. `Scripts/build-app.sh` packages the release SwiftPM executable with `Resources/Info.plist` into `build/Lynt.app` and signs it locally with an ad-hoc signature. This is local packaging, not notarized distribution. The bundle identifier is `com.lynt.personal-writing-assistant`.

## Data flow and isolation boundary

```text
Focused editable-field change + typing pause, or manual shortcut / paste
    → local captured field snapshot, if available
    → original document and UTF-16 ranges
    → ordered structural and lexical protection + merged intervals
    → sentence/newline-level prose extraction + local language gate
    → WritingReviewRequest containing eligible prose only
    → DeepSeek, with at most one configured Mistral fallback
    → response decoding, exact source anchors, local validation
    → category-labelled proposals and mutually exclusive overlaps
    → nonactivating suggestions panel or full review preview
    → explicit Accept / Ignore decisions
    → accepted edits applied from right to left
    → explicit Copy, or guarded Accessibility replacement
```

The provider receives `WritingReviewRequest`, never `PreparedDocument`, `CapturedText`, the original complete document, source offsets, or protected span values. The request contains the task, enabled categories, target tone, context kind, and segment IDs/text. A fixed system instruction describes the review task and response format. Normal reviews batch all eligible segments/categories into one request; an API failure can produce one additional request to the other configured provider, as requested by the user.

The user's later request for automatic suggestions supersedes the original brief's manual-only rule. Automatic mode defaults on, while the separate cloud setting defaults off for fresh preferences and retains its existing value on upgrades. Automatic mode therefore requires cloud enabled, Accessibility permission, a supported focused field, and provider configuration before it can review outside text.

Request inspection performs preparation locally and displays the isolated prose DTO without sending a request. It is useful for checking what a particular input would send; it cannot prove that every possible sensitive input is recognized.

## Protection and language selection

`ProtectionEngine` uses ordered block scans, delimiter balancing, line classification, inline lexical detectors, and interval merging. Covered patterns include explicit code fences, inline code, common source/configuration structures, HTTP traffic, stack traces/logs, paths, identifiers, URLs, search operators, numeric values, and common secret patterns. Unclosed recognized structures are preserved conservatively. This is not a full parser for each programming language.

Prose is extracted around protected ranges. Whitespace, markup, and protected islands remain in the original document; the model is never asked to recreate them. Numeric facts are immutable islands too. This may split an otherwise meaningful sentence into fragments that are too short to review.

`LanguageGate` runs Apple's local `NLLanguageRecognizer` on each remaining candidate, with additional Turkish/Azerbaijani characters and word signals. Clearly non-English and ambiguous/short candidates are skipped. `Review as English` permits certain ambiguous fragments but does not bypass technical/secret protection or explicit non-English signals. Detection remains heuristic: mixed clauses, uncommon names, transliteration, and very short searches can be skipped or misclassified. Conservative overprotection is an intentional tradeoff, not evidence of exhaustive safety.

## Suggestions and exact composition

`Models.swift` defines the current Codable wire contracts, documented for portable clients in [review-request.schema.json](Contracts/review-request.schema.json) and [review-response.schema.json](Contracts/review-response.schema.json). Runtime enforcement uses decoding and explicit local validation, not a generic JSON Schema engine. A response returns every requested segment ID exactly once and proposes `category`, `source`, `replacement`, and `explanation`; tone assessment is optional. Category names are `correctness`, `clarity`, `engagement`, and `delivery`.

`SuggestionValidator` finds a unique, literal source substring within that proposal's own segment. It derives UTF-16 offsets locally, verifies original source text and word boundaries, checks enabled categories, rejects excessive expansion/technical introductions, and discards duplicates or invalid proposals. Missing, duplicate, or unknown segment IDs invalidate the response. The model cannot select a document offset.

`TextRecomposer` accepts only locally known suggestion IDs whose source still matches the immutable original segment. Overlapping accepted edits cause an error; the UI prevents accepting a competing proposal until the first decision is undone. Replacements are applied from right to left. Every protected interval is remapped and checked again against its original UTF-16 sequence.

UTF-16 offsets match macOS Accessibility. Range conversion also checks Swift string boundaries. Snapshot and protected-text comparisons use exact UTF-16 sequences: ordinary Swift `String ==` permits canonical Unicode equivalence, which is too permissive for editor safety. No Unicode normalization or line-ending conversion is intended.

The four-color underlines appear inside Lynt's full preview. The floating panel displays the same textual category labels and colors beside a supported field, without inserting underlines into a third-party editor. Only accepted proposals change text. Tone defaults to Preserve; Delivery rewrites under Preserve are rejected while a qualified tone assessment can remain. Changing tone/context/category settings clears stale proposals; automatic mode can review again after returning to the editor. Model wording and semantic fidelity still require human judgment; local validators cannot prove that every proposed prose change preserves meaning.

`SuggestionRebaser` applies a single accepted, validated suggestion to the immutable source, reruns local protection and language gating, shifts unaffected anchors, drops overlaps, and revalidates the remaining proposals. The live controller uses this after a confirmed write so accepting one suggestion does not trigger another provider request. Unsupported target writes can open the full Review / Copy workflow. Full reviews adopted from a live snapshot also restrict Apply to one accepted suggestion, avoiding a wide range rewrite across multiple edits; Copy can assemble multiple accepted changes.

## Providers, failures, and cost controls

`LLMProvider` and `HTTPTransport` separate the prose contract from HTTP. Defaults are DeepSeek `deepseek-flash` and Mistral `ministral-3b-2512`, with editable HTTPS completion endpoints and model names. Credentials are read from Keychain only when configuring a review. The default DeepSeek endpoint and model follow its [official API documentation](https://api-docs.deepseek.com/); the fallback model follows [Mistral's Ministral 3 3B documentation](https://docs.mistral.ai/models/ministral-3-3b-25-12). Availability and API behavior may change.

Every review starts with DeepSeek when it has a configured key. Credit/authentication/rate/network/response errors can trigger one attempt with the other configured provider. If only Mistral is configured and fallback is enabled, it can be used directly. Cancellation never triggers fallback. Failure or rejected proposals never change the source editor. The UI identifies a successful fallback.

The ephemeral URLSession has no cookie storage or response cache, refuses redirects, imposes request/resource timeouts, and bounds response bytes. Both providers use JSON-object responses with local structural and suggestion validation; this does not assume a model will obey the prompt. No raw HTTP error body is shown or logged.

`TokenBudget` is an actor. It reserves conservative input-plus-maximum-output capacity for all permitted attempts before transmission, persists only month/counters, and settles known usage. Unknown network outcomes retain conservative charges; explicit rejected requests can release their charge. Reservations are charged before transmission so a crash cannot silently reset in-flight consumption. The limit is a local token control, not a provider-balance check or a currency spending guarantee. No current prices are hard-coded and no latency/quality benchmark has been established.

## macOS integration and lifecycle

`FocusedFieldService.capture()` retains the explicit manual flow: selected text is preferred even if offsets are unavailable, with a local full-field snapshot when needed for safe replacement. `captureLive()` reads the whole focused editable field with a 20,000 UTF-16-unit cap, independent of caret/selection. Both resolve the focused control and a bounded ancestry; when focus lands on a dialog/command-palette/list/combobox shell (common for Radix/cmdk modals), they also search a shallow descendant tree for the typed text field. They never walk an arbitrary window tree. Reported secure/protected controls are rejected. Automatic capture additionally requires editable evidence and rejects read-only controls before reading their value.

`FocusedFieldMonitor` observes focus/value/selection/geometry notifications on the frontmost application and current field through `AXObserver`. Notifications can be unsupported, so a roughly 0.65-second timer samples the focused control as a fallback. Excluded application identifiers are checked before content reads. The monitor uses no keyboard listener, clipboard reads, or full window-tree traversal. Chromium/Electron accessibility activation is requested once per process; native support can take time to materialize. This cannot expose arbitrary canvas-based or inaccessible editors.

`AutomaticReviewController` debounces changes for 1.2 seconds by default, prepares text off the main actor, and rechecks that the source app is frontmost with an unchanged element value before and after preparation and before presenting a result. A failed stability check clears the pending fingerprint so the next poll can retry; Electron/Chrome AX focus identities are not required to compare equal. `AutomaticReviewFingerprint` hashes length-prefixed exact UTF-16 text, target identity and review options. Caret/geometry changes do not create a new review version. `AutomaticReviewPolicy` keeps bounded in-memory suppression hashes, allows one active automatic review, enforces a 4-second minimum interval and 8 invocations per minute, and exposes a retry delay for the latest throttled candidate. Failed/cancelled/dismissed versions stay suppressed until their fingerprint changes. Provider token budgets remain a separate check.

The floating window is an `NSPanel` created with the nonactivating style, cannot become key/main, and is ordered without activating Lynt. It is stationary rather than transient so AppKit does not hide it when the source editor remains key. If the HUD briefly makes Lynt frontmost, monitoring does not treat that as a lost field. AX screen bounds are converted to AppKit coordinates and clamped to a visible screen frame. Automatic results are discarded when the user moves to another application or the target text changes. A separate sibling `AppModel` for live review shares preferences, Keychain access and budget with manual review, keeping their ephemeral results separate. Opening Lynt's Settings/full review pauses automatic monitoring; closing both resumes it.

Apply is always an explicit user action. It reactivates the source app, restores focus to the captured element when the floating HUD made Lynt frontmost, then verifies the captured element's unchanged full source text. Manual selections must remain compatible with their captured range; whole-field live reviews allow caret movement. Standard `AXTextField` / `AXTextArea` / `AXComboBox` controls prefer a whole-value write because Chromium often advertises selected-range APIs without honoring them. Contenteditable and other rich controls still use a minimal grapheme-safe selected-range edit when available; otherwise they remain Copy only. AX success is followed by an exact resulting-value check on the same element. Unexpected results are reported without blind retry or restoration. There is no simulated paste, automatic submission, browser search execution, or clipboard monitoring. Explicit Copy writes to the clipboard.

Review/apply tasks have cancellation and operation identities to reject late completions. Source text and decisions stay in ephemeral memory; preferences store automatic-mode settings/application exclusions, and budget persistence stores only month/counters. Keychain service `com.lynt.personal-writing-assistant.providers` uses accounts `deepseek` and `mistral`, with synchronization disabled. Accessibility permission is requested only through an explicit settings action.

Real editor compatibility must be established per application and field type; see [TESTING.md](TESTING.md) for actual execution results. Chrome/Safari search fields, ChatGPT/Claude prompts, Notes, TextEdit, rich editors, permission revocation and races can behave differently. [editor-smoke.html](docs/Fixtures/editor-smoke.html) supplies local synthetic input/textarea/contenteditable/password/read-only examples and event counters without network requests. Copy/manual paste remains the recovery path when safe replacement cannot be established.

## Deliberate remaining work

There is no persistent prompt history, disk result cache, provider balance polling, automated semantic equivalence check, Android app, IME, or universal editor adapter. The fixture corpus and Codable JSON boundary provide the starting point for Android; [ANDROID_PLAN.md](ANDROID_PLAN.md) describes the intended port. Protection should be expanded through failing real-world fixtures, and live-provider quality should be measured only after inspecting payload isolation with synthetic inputs.
