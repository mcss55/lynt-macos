import AppKit
import SwiftUI
import LyntCore

private final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel accepts mouse actions without taking keyboard focus away from the editor.
@MainActor
final class FloatingSuggestions {
    private let controller: AutomaticReviewController
    private let panel: NSPanel

    init(controller: AutomaticReviewController) {
        self.controller = controller
        panel = SuggestionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Lynt suggestions"
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.setAccessibilityLabel("Lynt automatic suggestions")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // `.transient` hides the panel as soon as Lynt is not the key app. This HUD
        // must stay while the user remains in the source editor.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: FloatingSuggestionView(controller: controller, model: controller.model))
    }

    func update() {
        guard controller.shouldShow, let capture = controller.snapshot else { panel.orderOut(nil); return }
        let count = min(3, controller.visibleSuggestions.count)
        let height: CGFloat = controller.model.isReviewing ? 112 : (controller.errorMessage != nil ? 210 : CGFloat(105 + max(1, count) * 155))
        let width: CGFloat = 390
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let anchor = capture.sourceBounds.map { NSRect(x: $0.minX, y: primaryTop - $0.maxY, width: $0.width, height: $0.height) }
        guard let screen = NSScreen.screens.first(where: { anchor.map($0.frame.intersects) ?? false }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        let field = anchor?.intersection(visible)
        let safeField = (field?.isNull == false && field?.isEmpty == false) ? field! : NSRect(x: visible.maxX, y: visible.maxY - 100, width: 0, height: 0)
        let actualHeight = min(height, visible.height)
        let x = min(max(safeField.maxX - width, visible.minX), visible.maxX - width)
        var y = safeField.minY - actualHeight - 8
        if y < visible.minY { y = safeField.maxY + 8 }
        y = min(max(y, visible.minY), visible.maxY - actualHeight)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: actualHeight), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

private struct FloatingSuggestionView: View {
    @ObservedObject var controller: AutomaticReviewController
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "text.badge.checkmark").foregroundStyle(.teal)
                Text("Lynt").font(.headline)
                Text(model.isReviewing ? "Checking English…" : "\(controller.visibleSuggestions.count) suggestions").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { controller.dismiss() } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss suggestions until this text changes")
            }.padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            if model.isReviewing {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("You can keep typing.").font(.caption).foregroundStyle(.secondary); Spacer() }.padding(16)
            } else if let error = controller.errorMessage {
                VStack(alignment: .leading, spacing: 12) {
                    Text(error).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                    HStack {
                        if !model.suggestions.isEmpty {
                            Button("Review / Copy") { controller.openFullReview?() }.buttonStyle(.borderedProminent)
                        }
                        Button("Open Settings") { controller.openSettings?() }
                    }
                }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(controller.visibleSuggestions.prefix(3))) { suggestion in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(suggestion.category.label, systemImage: suggestion.category.symbol)
                                    .font(.caption.weight(.semibold)).foregroundStyle(suggestion.category.color)
                                (Text(suggestion.source).strikethrough().foregroundColor(.secondary) + Text("  →  ") + Text(suggestion.replacement.isEmpty ? "(remove)" : suggestion.replacement).foregroundColor(suggestion.category.color))
                                    .font(.callout).lineLimit(3)
                                Text(suggestion.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                HStack {
                                    if controller.snapshot?.canReplace == true {
                                        Button("Accept & apply") { controller.apply(suggestion) }
                                            .buttonStyle(.borderedProminent).tint(suggestion.category.color)
                                    } else {
                                        Button("Review / Copy") { controller.openFullReview?() }.buttonStyle(.borderedProminent)
                                    }
                                    Button("Ignore") { controller.ignore(suggestion) }.buttonStyle(.bordered)
                                    Spacer()
                                    if controller.isApplying { ProgressView().controlSize(.mini) }
                                }.controlSize(.small).disabled(controller.isApplying)
                            }.padding(14)
                            if suggestion.id != controller.visibleSuggestions.prefix(3).last?.id { Divider().padding(.horizontal, 14) }
                        }
                    }
                }
                Divider()
                HStack {
                    Text(model.providerDescription).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Review all…") { controller.openFullReview?() }.buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
        }.frame(width: 390).frame(maxHeight: .infinity, alignment: .top)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.12)))
    }
}
