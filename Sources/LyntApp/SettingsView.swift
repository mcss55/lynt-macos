import SwiftUI
import LyntCore
import LyntPlatform

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    let updateShortcut: () -> Void
    @State private var deepseekKey = ""
    @State private var mistralKey = ""
    @State private var savedDeepseek = false
    @State private var savedMistral = false
    @State private var status = ""
    @State private var keyError = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable cloud review", isOn: $preferences.cloudEnabled)
                Text("Cloud review sends eligible English prose after a typing pause when automatic suggestions are on, or when you choose Review. Detected technical ranges and skipped languages are excluded locally. No text history or analytics is stored.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Automatically use the other provider on an API error", isOn: $preferences.fallbackEnabled)
                Text("DeepSeek is tried first. If it fails or has no credit, the same safe prose can be sent once to Ministral 3 3B. Every new review starts with DeepSeek. A fallback is shown in the result.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Privacy & fallback") }
            Section {
                Toggle("Automatic suggestions after typing", isOn: $preferences.automaticReviewEnabled)
                Slider(value: $preferences.reviewDelaySeconds, in: 0.8...5, step: 0.2) {
                    Text("Typing pause")
                } minimumValueLabel: { Text("0.8s") } maximumValueLabel: { Text("5s") }
                Text("Check after \(preferences.reviewDelaySeconds, specifier: "%.1f") seconds of inactivity. Only the focused editable field is observed through Accessibility; keyboard events are not captured. Suggestions appear beside the field and never apply automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Repeated text is skipped, with a 4-second minimum interval and at most 8 automatic reviews per minute. The monthly token budget still applies. Close Lynt's review/settings windows to resume checks in other apps.")
                    .font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(model.fields.isAccessibilityTrusted ? "Accessibility: Allowed" : "Accessibility: Not allowed",
                              systemImage: model.fields.isAccessibilityTrusted ? "checkmark.shield" : "exclamationmark.shield")
                            .foregroundStyle(model.fields.isAccessibilityTrusted ? Color.green : Color.orange)
                        if !model.fields.isAccessibilityTrusted {
                            Button("Allow Accessibility for automatic suggestions") { model.fields.requestAccessibilityPermission() }
                        }
                    }
                }
                ForEach(preferences.excludedApplications.sorted(), id: \.self) { id in
                    HStack {
                        Text(id).font(.caption)
                        Spacer()
                        Button("Resume") { preferences.excludedApplications.remove(id) }.controlSize(.small)
                    }
                }
                Text("Use Pause in [application] from the menu bar to exclude that app before its text is read. Some custom editors do not expose editable text; use manual paste there.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Automatic suggestions") }
            Section {
                credentialRow("DeepSeek · Default", id: "deepseek", key: $deepseekKey, saved: savedDeepseek)
                TextField("Model", text: $preferences.deepseekModel)
                TextField("Completion endpoint", text: $preferences.deepseekEndpoint)
                    .help("Your API key and eligible prose will be sent to this HTTPS URL.")
            } header: { Text("DeepSeek") }
            Section {
                credentialRow("Ministral 3 3B · Fallback", id: "mistral", key: $mistralKey, saved: savedMistral)
                TextField("Model", text: $preferences.mistralModel)
                TextField("Completion endpoint", text: $preferences.mistralEndpoint)
            } header: { Text("Mistral") }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(keyError ? .orange : .secondary)
            }
            Section {
                ForEach(SuggestionCategory.allCases) { category in
                    Toggle(isOn: Binding(get: { preferences.enabledCategories.contains(category) }, set: { enabled in
                        if enabled { preferences.enabledCategories.insert(category) } else { preferences.enabledCategories.remove(category) }
                    })) {
                        Label(category.label, systemImage: category.symbol).foregroundStyle(category.color)
                    }
                }
                HStack {
                    Button("All categories") { preferences.enabledCategories = Set(SuggestionCategory.allCases) }
                    Button("Correctness only") { preferences.enabledCategories = [.correctness] }
                }
                Text("Search mode always requests correctness only. Tone defaults to Preserve original. Changing review settings cancels stale suggestions and starts a fresh automatic check after you return to the editor.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Review categories") }
            Section {
                Stepper(value: $preferences.monthlyTokenLimit, in: 10_000...5_000_000, step: 10_000) {
                    Text("Monthly limit: \(preferences.monthlyTokenLimit.formatted()) tokens")
                }
                Stepper(value: $preferences.maxOutputTokens, in: 400...4_000, step: 200) {
                    Text("Maximum output per API attempt: \(preferences.maxOutputTokens.formatted()) tokens")
                }
                Text("The local token budget reserves room for both providers before sending. Failed or unknown usage is counted conservatively. This is a local usage cap, not your provider balance or a currency estimate.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.budgetDescription).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Cost controls") }
            Section {
                Picker("Review key", selection: $preferences.shortcutKey) {
                    Text("G").tag(UInt32(5)); Text("E").tag(UInt32(14)); Text("R").tag(UInt32(15)); Text("L").tag(UInt32(37))
                }
                Picker("Modifiers", selection: $preferences.shortcutModifiers) {
                    Text("⌘⇧ Command Shift").tag(ShortcutModifiers([.command, .shift]).rawValue)
                    Text("⌘⌥ Command Option").tag(ShortcutModifiers([.command, .option]).rawValue)
                    Text("⌃⌥ Control Option").tag(ShortcutModifiers([.control, .option]).rawValue)
                }
                Button("Register shortcut", action: updateShortcut)
                HStack {
                    Button("Request Accessibility access") { model.fields.requestAccessibilityPermission() }
                    Button("Open Accessibility settings") { model.fields.openAccessibilitySettings() }
                }
                Text("Accessibility reads the focused editable field while automatic suggestions are enabled, or on an explicit review. Accepted edits require a fresh snapshot check. Secure and read-only fields are excluded. You can also paste manually and copy the result.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("macOS integration") }
        }.formStyle(.grouped).frame(width: 630, height: 760)
            .task { loadKeyStatus(); await model.refreshBudget() }
    }

    private func credentialRow(_ label: String, id: String, key: Binding<String>, saved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).fontWeight(.medium)
                Spacer()
                Label(saved ? "Saved in Keychain" : "Not configured", systemImage: saved ? "key.fill" : "key")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                SecureField(saved ? "Enter a new key to replace" : "API key", text: key)
                Button("Save") { saveKey(key.wrappedValue, id: id); key.wrappedValue = "" }.disabled(key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Delete") { deleteKey(id) }.disabled(!saved)
            }
        }
    }

    private func loadKeyStatus() {
        do { savedDeepseek = try model.keys.get("deepseek") != nil; savedMistral = try model.keys.get("mistral") != nil }
        catch { status = error.localizedDescription; keyError = true }
    }
    private func saveKey(_ value: String, id: String) {
        do {
            try model.keys.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: id)
            status = "API key saved in macOS Keychain."; keyError = false; loadKeyStatus()
        } catch { status = error.localizedDescription; keyError = true }
    }
    private func deleteKey(_ id: String) {
        do { try model.keys.delete(id); status = "Stored key deleted."; keyError = false; loadKeyStatus() }
        catch { status = error.localizedDescription; keyError = true }
    }
}
