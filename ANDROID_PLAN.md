# Android plan — future work

No Android app, Gradle project, keyboard, or Android Accessibility service is implemented in this repository. The current deliverable is the macOS application. Keep Android as a separate Kotlin/Jetpack Compose client without adding a backend or an account system.

## Start with selected-text processing

Use Android's `ACTION_PROCESS_TEXT` activity integration for text selected in supporting applications. Retrieve `EXTRA_PROCESS_TEXT` as a `CharSequence`, respect `EXTRA_PROCESS_TEXT_READONLY`, and offer Copy when replacement is unavailable. These APIs describe the selected-text exchange; behavior in each host editor still needs testing. See the official [Intent process-text contract](https://developer.android.com/reference/android/content/Intent#ACTION_PROCESS_TEXT) and [read-only extra](https://developer.android.com/reference/android/content/Intent#EXTRA_PROCESS_TEXT_READONLY).

Show the selected original, eligible prose/skip status, four labelled categories, estimated tone, individual Accept/Ignore controls, accepted-only preview, and Cancel. Begin with cloud review disabled and manual paste as a fallback. Never submit a prompt or trigger a search. Require a fresh explicit review after tone/category/context changes. Treat host formatting and lifecycle limitations conservatively rather than promising universal replacement.

## Port behavior through contracts and fixtures

The portable boundary is the JSON request/response shape defined by `Sources/LyntCore/Models.swift` and the shared [request](Contracts/review-request.schema.json) / [response](Contracts/review-response.schema.json) schemas: stable segment IDs, prose-only input, enabled categories, context, target tone, exact source substrings, replacements, explanations, and optional subjective tone assessment. No model-provided offsets or reconstructed complete documents are accepted.

Port deterministic protection and merged intervals first. Reuse `Tests/LyntCoreTests/Fixtures/protection-corpus.json` and expand fixtures to record expected UTF-16 ranges, eligible segment payloads, accepted edits, and exact recomposed output. Kotlin strings use UTF-16; explicitly preserve surrogate pairs, combining characters, CRLF, and protected content, and do not normalize. Require unique literal anchors, reject overlapping accepted edits, apply from right to left, and compare every protected interval after composition.

Apple NaturalLanguage cannot be reused on Android. Select and test a local language gate before enabling cloud processing, with separate Turkish/Azerbaijani, transliterated, mixed-clause, and short-search fixtures. Ambiguity must preserve the text; a manual English override must not bypass content protection.

## Providers, credentials, and lifecycle

Port the current DeepSeek-first, one-attempt-per-provider policy. On an eligible API failure, optionally send the same isolated prose request once to configured Mistral Ministral 3 3B. Never fallback after cancellation, never send protected originals, and make the active provider visible. Preserve bounded response sizes, HTTPS-only configurable endpoints, no redirects, finite timeouts, strict local response validation, and conservative monthly token reservation across both attempts.

Use an Android platform credential store backed by Keystore; choose the concrete encrypted-storage mechanism during implementation and review its current official documentation. Do not store API keys or source text in plain preferences, logs, saved-instance state, analytics, crash reports, or backups. Activity recreation/process death must discard stale replacement authority; restoring a UI must never silently resume cloud requests or apply old edits. Copy/return only after explicit acceptance and host-contract checks.

## Readiness checks

Before release, run the shared corpus in Swift and Kotlin, compare exact payloads/results, and test supported Android versions and real native/browser editors. Exercise read-only selections, absent extras, backgrounding, process death, rotation, cancellation, changed source selections, offline/credit/rate-limit failures, response injection, Unicode, and rich text. Establish per-app support claims only from those results.

Consider an IME only if selected-text processing proves inadequate in daily use. An IME requires a separate `InputMethodService` implementation and lifecycle design, as described in Android's [input-method guide](https://developer.android.com/develop/ui/views/touch-and-input/creating-input-method). It remains a separate future decision; no background checking or keyboard implementation is planned for the current MVP.
