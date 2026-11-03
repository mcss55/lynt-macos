import SwiftUI
import AppKit
import LyntCore

extension SuggestionCategory {
    var color: Color {
        switch self { case .correctness: .red; case .clarity: .blue; case .engagement: .green; case .delivery: .purple }
    }
    var nsColor: NSColor {
        switch self { case .correctness: .systemRed; case .clarity: .systemBlue; case .engagement: .systemGreen; case .delivery: .systemPurple }
    }
    var symbol: String {
        switch self { case .correctness: "checkmark.circle"; case .clarity: "line.3.horizontal.decrease"; case .engagement: "sparkle"; case .delivery: "bubble.left" }
    }
}

struct ReviewView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    let showSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 14) {
                Picker("Context", selection: $preferences.context) {
                    ForEach(ContextKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.frame(width: 175)
                Picker("Target tone", selection: $preferences.tone) {
                    ForEach(ToneTarget.allCases, id: \.self) { Text($0 == .preserve ? "Preserve original" : $0.rawValue.capitalized).tag($0) }
                }.frame(width: 260)
                Spacer()
                if model.isReviewing { ProgressView().controlSize(.small) }
                Menu {
                    Button("Review as English") { model.review(forceEnglish: true) }
                    Button("Inspect outgoing request") { model.inspectRequest() }
                    Divider()
                    Button("Local playground") { model.playground() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
                Button("Review English") { model.review() }
                    .buttonStyle(.borderedProminent).keyboardShortcut("r", modifiers: .command)
                    .disabled(model.input.isEmpty || model.isReviewing || model.isApplying)
            }.padding(.horizontal, 24).padding(.vertical, 14)

            HStack(spacing: 8) {
                filterButton(nil, label: "All", count: model.suggestions.count)
                ForEach(SuggestionCategory.allCases) { category in
                    filterButton(category, label: category.label, count: model.suggestions.filter { $0.category == category }.count)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 24).padding(.bottom, 14)

            HSplitView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(model.document == nil ? "Your text" : "Review original", systemImage: "text.alignleft")
                            .font(.headline)
                        Spacer()
                        if model.document != nil {
                            Button("Edit text") { model.clearReview(); model.captured = nil }.buttonStyle(.plain).foregroundStyle(.tint)
                        }
                    }
                    if model.document != nil {
                        UnderlinedText(text: model.input, suggestions: model.filteredSuggestions.filter { !model.ignored.contains($0.id) }, accepted: model.accepted, selectedID: model.selectedID) { model.selectedID = $0 }
                            .frame(minHeight: 180)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
                    } else {
                        PlainTextEditor(text: Binding(get: { model.input }, set: { model.input = $0; model.editedInput() }))
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
                            .accessibilityLabel("Text to review. Technical content remains local.")
                    }
                    if let document = model.document {
                        HStack(spacing: 12) {
                            Label("\(document.protectedSpans.count) protected ranges", systemImage: "lock.shield")
                            Text("\(document.segments.count) English segments")
                            if !document.skipped.isEmpty { Text("\(document.skipped.count) skipped") }
                        }.font(.caption).foregroundStyle(.secondary)
                        if !document.skipped.isEmpty {
                            DisclosureGroup("Why text was skipped") {
                                ForEach(Array(Set(document.skipped.map(\.reason))).sorted(), id: \.self) { reason in
                                    Text(reason).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.font(.caption)
                        }
                    } else {
                        Text("Detected technical ranges stay local. Inspect outgoing prose before cloud review.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20).frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Suggestions").font(.headline)
                        Spacer()
                        Text("\(model.accepted.count) accepted").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.suggestions.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "text.badge.checkmark").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                            Text(model.document == nil ? "Make your writing clearer" : "Your text is unchanged").font(.headline)
                            Text(model.document == nil ? "Review on demand, then choose each change. Try the local playground to explore all four categories." : "Only accepted suggestions change the final text.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if model.document == nil { Button("Try local playground") { model.playground() } }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(model.filteredSuggestions) { suggestion in
                                    suggestionRow(suggestion)
                                }
                            }.padding(1)
                        }
                    }
                    if let tone = model.toneAssessment {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Tone · \(tone.label)", systemImage: "bubble.left").font(.caption.weight(.semibold)).foregroundStyle(.purple)
                            Text(tone.note).font(.caption).foregroundStyle(.secondary)
                            Text("Tone is subjective; short text gives limited context.").font(.caption2).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(20).frame(minWidth: 300, idealWidth: 340, maxWidth: 420, maxHeight: .infinity)
            }.frame(minHeight: 300)

            if !model.accepted.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Accepted version", systemImage: "checkmark.seal").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    ScrollView { Text(model.assembled).textSelection(.enabled).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
                }.padding(.horizontal, 24).padding(.vertical, 14)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.isError ? "exclamationmark.circle" : "info.circle").foregroundStyle(model.isError ? .orange : .secondary)
                    Text(model.message).font(.callout).foregroundStyle(model.isError ? .orange : .secondary).textSelection(.enabled)
                    Spacer(minLength: 0)
                }.accessibilityElement(children: .combine)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.providerDescription).font(.caption)
                        if !model.budgetDescription.isEmpty { Text(model.budgetDescription).font(.caption2).foregroundStyle(.secondary) }
                    }.foregroundStyle(.secondary)
                    Spacer()
                    Button(model.isReviewing ? "Cancel review" : "Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                    Button("Copy") { model.copy() }.disabled(model.input.isEmpty || model.isReviewing || model.isApplying)
                    Button("Apply accepted") { model.apply() }.disabled(!model.canApply)
                        .help(model.captured?.isLiveCapture == true && model.accepted.count > 1 ? "Apply live suggestions one at a time, or Copy the assembled version." : (model.captured?.canReplace == true ? "Revalidate the original field and apply accepted changes." : "This review supports Copy only. Capture a supported editable field to apply changes."))
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(minWidth: 920, minHeight: 650)
            .background(Color(nsColor: .windowBackgroundColor))
            .sheet(isPresented: $model.showingRequest) { requestSheet }
            .task { await model.refreshBudget() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.badge.checkmark").font(.system(size: 26, weight: .medium)).foregroundStyle(.teal)
                .frame(width: 44, height: 44).background(.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Lynt").font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("A little clarity, on your terms.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isDemo { Text("LOCAL PLAYGROUND").font(.caption2.weight(.semibold)).foregroundStyle(.teal).padding(7).background(.teal.opacity(0.08), in: Capsule()) }
            Button(action: showSettings) { Image(systemName: "gearshape").font(.title3) }.buttonStyle(.plain).accessibilityLabel("Settings")
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }

    private func filterButton(_ category: SuggestionCategory?, label: String, count: Int) -> some View {
        Button { model.filter = category } label: {
            HStack(spacing: 6) {
                if let category { Image(systemName: category.symbol).foregroundStyle(category.color) }
                Text(label)
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 7)
                .background(model.filter == category ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.filter == category ? Color.accentColor.opacity(0.3) : .clear))
        }.buttonStyle(.plain).accessibilityLabel("Filter \(label), \(count) suggestions")
    }

    private func suggestionRow(_ suggestion: Suggestion) -> some View {
        let selected = model.selectedID == suggestion.id
        let accepted = model.accepted.contains(suggestion.id)
        let ignored = model.ignored.contains(suggestion.id)
        let conflict = model.isConflicting(suggestion)
        return VStack(alignment: .leading, spacing: 10) {
            Button { model.selectedID = suggestion.id } label: {
                HStack(spacing: 7) {
                    Image(systemName: suggestion.category.symbol).foregroundStyle(suggestion.category.color)
                    Text(suggestion.category.label).font(.caption.weight(.semibold))
                    Spacer()
                    if accepted { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Accepted") }
                    if ignored { Text("Ignored").font(.caption2).foregroundStyle(.secondary) }
                    if conflict { Image(systemName: "arrow.triangle.branch").accessibilityLabel("Conflicts with an accepted suggestion") }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if selected {
                Text(suggestion.source).strikethrough().foregroundStyle(.secondary).textSelection(.enabled)
                Text(suggestion.replacement.isEmpty ? "(remove)" : suggestion.replacement).foregroundStyle(suggestion.category.color).textSelection(.enabled)
                Text(suggestion.explanation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if conflict {
                    Text("Alternative to an accepted change. Undo that change to choose this one.").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    if accepted || ignored {
                        Button("Undo decision") { model.undoDecision(suggestion) }
                    } else {
                        Button("Accept") { model.accept(suggestion) }.buttonStyle(.borderedProminent).tint(suggestion.category.color).disabled(conflict)
                        Button("Ignore") { model.ignore(suggestion) }
                    }
                    Spacer()
                }.controlSize(.small)
            } else {
                Button { model.selectedID = suggestion.id } label: {
                    Text(suggestion.source).font(.callout).lineLimit(2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color(nsColor: .textBackgroundColor) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? suggestion.category.color.opacity(0.45) : Color.primary.opacity(0.06)))
            .opacity(ignored ? 0.6 : 1)
    }

    private var requestSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Outgoing prose payload", systemImage: "lock.shield").font(.title2.weight(.semibold))
            Text("Prepared locally. No request is made by this inspection. The provider also receives fixed review instructions and response schema; those contain no document content.").foregroundStyle(.secondary)
            ScrollView { Text(model.requestPreview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack { Spacer(); Button("Done") { model.showingRequest = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 720, height: 510)
    }
}

/// System substitutions must never rewrite developer input before protection runs.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: 14)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Text to review. Technical content remains local.")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let view = scroll.documentView as? NSTextView,
              !view.string.utf16.elementsEqual(text.utf16) else { return }
        view.string = text
        view.undoManager?.removeAllActions()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// Links represent locally assigned suggestion IDs. They never navigate or open a URL.
struct UnderlinedText: NSViewRepresentable {
    var text: String
    var suggestions: [Suggestion]
    var accepted: Set<String>
    var selectedID: String?
    var select: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.linkTextAttributes = [:]
        view.setAccessibilityLabel("Original text with category-labelled suggestions. Use the suggestions list for keyboard review.")
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.select = select
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        for suggestion in suggestions.sorted(by: { $0.id != selectedID && $1.id == selectedID }) {
            guard suggestion.range.substring(in: text) == suggestion.source else { continue }
            attributed.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                      .underlineColor: suggestion.category.nsColor,
                                      .link: suggestion.id,
                                      .toolTip: "\(suggestion.category.label): \(suggestion.explanation)"], range: suggestion.range.nsRange)
            if accepted.contains(suggestion.id) { attributed.addAttribute(.backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.10), range: suggestion.range.nsRange) }
            if selectedID == suggestion.id { attributed.addAttribute(.backgroundColor, value: suggestion.category.nsColor.withAlphaComponent(0.12), range: suggestion.range.nsRange) }
        }
        view.textStorage?.setAttributedString(attributed)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var select: (String) -> Void
        init(select: @escaping (String) -> Void) { self.select = select }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let id = link as? String { select(id) }
            return true
        }
    }
}
