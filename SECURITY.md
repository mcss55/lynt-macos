# Security and privacy

Lynt is a local macOS application with optional cloud review. It has no application backend, account system, analytics, or saved prompt history. Cloud review is **off by default**. Adding an API key does not enable it.

Automatic suggestions are **on by default**, following the user's explicit request to check focused fields after typing pauses. The separate cloud setting and Accessibility permission are still required; an existing cloud preference is preserved during an upgrade. When both are enabled, eligible text can be sent without pressing Review for each edit. Turn automatic suggestions off for manual-only processing.

## What can leave the Mac

Either a manual **Review English** / **Review as English** action or an enabled automatic typing-pause review prepares the text locally. Automatic mode reads the whole focused supported editable field, up to 20,000 UTF-16 units; manual capture prefers selected text. The protection engine identifies technical and sensitive ranges, merges their UTF-16 intervals, and applies local language detection to the remaining fragments. The provider receives a `WritingReviewRequest` containing only eligible prose segments, local segment IDs, categories, context, and tone preferences, together with a fixed editing instruction. It does not receive the original-document object, captured app/window identity, selection offsets, or detected protected ranges.

**Inspect outgoing prose** shows that request DTO locally without making a network request. It excludes detected protected content; it is not a guarantee that undetected sensitive information has been removed. The preview contains the eligible prose itself and is not persisted by Lynt. The actual HTTP envelope also includes the configured model, response mode, token cap, and fixed instruction.

Requests containing no eligible segments make zero API calls. A language override does not disable technical/secret protection. Category or tone changes invalidate old suggestions; automatic mode can review the new configuration after the user returns to the editor. Disabling cloud or automatic review cancels the associated automatic work. Cancellation cannot retract bytes already transmitted.

To inspect sensitive text before any network request, first disable automatic suggestions, then use manual request inspection. Merely opening the preview after typing into an automatically monitored field does not imply that an earlier automatic request was prevented.

## Two providers and fallback

DeepSeek is the default provider. With fallback enabled and both keys configured, an API error can send the **same extracted prose** once to Mistral's Ministral 3 3B. Every new review starts with DeepSeek. The result identifies the successful provider and indicates fallback. Turning fallback off prevents the second attempt. User cancellation does not trigger fallback. This behavior follows the user's explicit requirement and supersedes the original brief's single-provider restriction.

Provider endpoints and models are configurable. The endpoint receives its configured API key and eligible prose: use only endpoints you trust. URLs require HTTPS and reject embedded credentials, query strings, and fragments. Redirects are refused. The URL session is ephemeral, disables its URL cache and cookie storage, and has finite request/resource timeouts. Responses are capped at 256 KiB, including a 128 KiB model-content cap. Provider error bodies are not surfaced or logged; error messages report safe status/reason descriptions.

Provider-side retention and processing are governed by the provider and account configuration. Local filtering does not control provider storage. The implementation has been tested with mocked transports; real provider integration and output quality require separate verification.

## Credentials and local storage

- API keys are generic-password items in macOS Keychain under service `com.lynt.personal-writing-assistant.providers`, with account `deepseek` or `mistral`.
- Newly created items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; synchronization is disabled. Settings can replace or delete each key. Lynt does not save keys in `UserDefaults`, source files, or its diagnostics.
- Preferences store provider models/endpoints, category/tone/context settings, shortcut configuration, automatic-mode delay and enabled flag, excluded application bundle identifiers, and budget settings. Budget persistence contains month and token counters only.
- Original text, captured field snapshots, outgoing-prose previews, suggestions, and accepted edits stay in process memory during the review. Cancel clears the review references and input. This is not a cryptographic memory wipe; the OS and tools outside Lynt may retain memory or crash diagnostics.
- **Copy** intentionally writes the assembled accepted version to the system clipboard. Lynt does not automatically read the clipboard or simulate paste. Clipboard history tools may retain copied content.

## Editing safeguards

The model proposes exact source substrings, not authoritative offsets or reconstructed documents. Local validation requires known segment IDs, a unique literal match, valid character/word boundaries, enabled categories, bounded edits, and no overlap with protected ranges. Technical material introduced in a proposed replacement is rejected. Recomposition uses only accepted edits, works right to left, and rechecks protected content byte-for-byte in its UTF-16 representation. Competing overlapping edits cannot be accepted together.

While automatic mode and cloud review are enabled, `FocusedFieldMonitor` subscribes to Accessibility focus/value notifications and samples only the focused editable field at about 0.65-second intervals as a fallback. It does not install keyboard event taps, read the clipboard, or traverse arbitrary window/page content. Secure/protected fields and read-only controls are rejected before reading their values. Excluded application identifiers are checked before future field reads. The manual shortcut still uses Carbon hotkey registration.

Lynt windows pause outside-field automatic monitoring. Context changes invalidate pending results; the controller rechecks the target before preparation, after preparation, before showing results, and before applying. A local hash of target identity, exact UTF-16 text and review options prevents repeated requests without persisting the text or hashes. An unchanged field can still be reviewed on focus; this is not limited to characters typed while Lynt was already observing it.

For Chromium/Electron applications, the adapter can request their accessibility tree using documented assistive-technology activation attributes, once per process. It does not change browser launch flags, execute page JavaScript, or read the whole page as a fallback. Some custom editors expose no usable editable value and remain unsupported.

The floating panel is nonactivating and does not automatically take keyboard focus. **Accept & apply** explicitly accepts one suggestion, verifies application/window/element/full text, and applies a locally computed edit; it never submits a form or prompt. Moving the caret alone does not invalidate a whole-field automatic review. When supported, a minimal selected range is verified before replacement; standard text fields can support a whole-value write. Rich/multiline editors without a safe selected-text path remain Copy only. Remaining suggestions are rebased and revalidated locally without another provider request.

Manual Apply can reactivate its captured source after the user's action and also checks the original selection when required. A write is checked against the expected resulting value; a failed check does not trigger an automatic retry or blind rollback. Accessibility calls cannot provide an atomic transaction with an external editor, so last-moment editor races cannot be ruled out.

## Cost controls and limits

The monthly local token cap reserves a conservative input bound plus maximum output for every possible attempt **before transmission**. A successful response settles reported usage; unknown outcomes, including cancellation after dispatch, retain a conservative charge. Explicit authentication, credit, rate, and request-format rejections release their reservation. Unattempted fallback reservations are released. Reservations are persisted as charged before dispatch, so restarting during a request does not erase its possible usage.

These are local usage counters, not the provider's billing ledger, credit balance, or a guaranteed currency limit. Provider settings and tokenizers may change. A new month resets the counters using the Mac's local calendar.

Automatic mode waits 1.2 seconds by default (configurable from 0.8 to 5), skips duplicate versions, allows one automatic review at a time, and limits invocations to at least 4 seconds apart and at most 8 per minute. A fallback is part of the same review invocation and can add one provider request. The existing monthly token preflight still applies. Ignoring/dismissing or cancelling a version does not automatically retry the same version.

## Detection limitations

Protection is deterministic and conservative, but heuristic. It is not a complete parser for every programming language, document format, log grammar, or secret type. A natural-language passphrase, unfamiliar code syntax, malformed markup, or content whose boundaries cannot be inferred may evade detection. Language identification can also be uncertain, especially for short or mixed-language fragments. The app cannot prove that a stylistic suggestion preserves meaning; every edit requires acceptance.

Pause automatic suggestions or exclude the application before entering sensitive material. You can then inspect the outgoing prose manually, fence technical material to make boundaries explicit, or keep cloud review disabled. Do not treat passing fixtures as a universal no-leak guarantee. See [TESTING.md](TESTING.md) for executed checks and unverified integration surfaces.

## Implementation references

- [DeepSeek JSON output](https://api-docs.deepseek.com/guides/json_mode/)
- [DeepSeek error codes](https://api-docs.deepseek.com/quick_start/error_codes/)
- [DeepSeek thinking-mode controls](https://api-docs.deepseek.com/guides/thinking_mode/)
- [Mistral chat endpoint](https://docs.mistral.ai/api/endpoint/chat)
- [Mistral JSON mode](https://docs.mistral.ai/studio/conversations/structured-output/json_mode)
- [Apple Accessibility notifications](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)
- [Chromium accessibility activation](https://www.chromium.org/developers/design-documents/accessibility/)
- [Electron accessibility activation](https://github.com/electron/electron/blob/main/docs/tutorial/accessibility.md)

No real credentials or production payloads should be added to bug reports or fixtures. Use synthetic examples when reporting detection failures.
