import AppKit
import SwiftUI

// The pointing-hand cursor over everything clickable. SwiftUI on macOS leaves the arrow everywhere, so:
// - SwiftUI buttons get it from `PointerButtonStyle`, which wraps the usual styles (plain, bordered, link, …) and is also
//   the default style at the window root, so buttons without an explicit style get it too;
// - AppKit-backed controls (toggles, pop-up and segmented pickers, menus, checkboxes) get it from `PointerCursorMonitor`,
//   which looks at the NSView under the pointer. Text fields keep their I-beam.

extension View {
    /// Shows the pointing hand while the pointer is over this view (and it is enabled).
    func pointerCursor(_ enabled: Bool = true) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: if enabled { NSCursor.pointingHand.set() } else if NSCursor.current == NSCursor.pointingHand { NSCursor.arrow.set() }
            // Only undo our own cursor, so an I-beam or resize cursor set by a neighbour is left alone.
            case .ended: if NSCursor.current == NSCursor.pointingHand { NSCursor.arrow.set() }
            }
        }
    }
}

/// A button style that draws like `base` and shows the pointing hand on hover, except when the button is disabled.
struct PointerButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    var base: Base
    init(_ base: Base) { self.base = base }
    func makeBody(configuration: Configuration) -> some View { PointerButton(configuration: configuration, base: base) }

    private struct PointerButton: View {
        @Environment(\.isEnabled) private var isEnabled
        var configuration: PrimitiveButtonStyleConfiguration
        var base: Base
        var body: some View { Button(configuration).buttonStyle(base).pointerCursor(isEnabled) }
    }
}

extension PrimitiveButtonStyle where Self == PointerButtonStyle<PlainButtonStyle> { static var plainPointer: Self { .init(.plain) } }
extension PrimitiveButtonStyle where Self == PointerButtonStyle<BorderedButtonStyle> { static var borderedPointer: Self { .init(.bordered) } }
extension PrimitiveButtonStyle where Self == PointerButtonStyle<BorderedProminentButtonStyle> { static var borderedProminentPointer: Self { .init(.borderedProminent) } }
extension PrimitiveButtonStyle where Self == PointerButtonStyle<LinkButtonStyle> { static var linkPointer: Self { .init(.link) } }
extension PrimitiveButtonStyle where Self == PointerButtonStyle<BorderlessButtonStyle> { static var borderlessPointer: Self { .init(.borderless) } }
extension PrimitiveButtonStyle where Self == PointerButtonStyle<DefaultButtonStyle> { static var automaticPointer: Self { .init(.automatic) } }

private struct EventBox: @unchecked Sendable { let event: NSEvent }

/// The pointing hand over AppKit-backed controls, app-wide. Installed once at launch.
@MainActor final class PointerCursorMonitor {
    static let shared = PointerCursorMonitor()
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    private var showingHand = false

    func install() {
        guard monitor == nil else { return }
        for window in NSApp.windows { window.acceptsMouseMovedEvents = true }
        // Sheets and new windows need mouse-moved events too.
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            if let window = note.object as? NSWindow, !window.acceptsMouseMovedEvents { window.acceptsMouseMovedEvents = true }
        }
        // Local monitors run on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .cursorUpdate, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            let box = EventBox(event: event)
            return MainActor.assumeIsolated { self.handle(box.event) }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, let content = window.contentView else { return event }
        let point = content.convert(event.locationInWindow, from: nil)
        if let view = content.hitTest(point), Self.isClickable(view) {
            NSCursor.pointingHand.set(); showingHand = true
            // Keep AppKit from resetting the cursor for this control's own tracking area.
            return event.type == .cursorUpdate ? nil : event
        }
        if showingHand {
            showingHand = false
            if NSCursor.current == NSCursor.pointingHand { NSCursor.arrow.set() }
        }
        return event
    }

    /// An enabled AppKit control that acts on a click, found at or above the hit view. Editable text stays an I-beam.
    static func isClickable(_ hit: NSView) -> Bool {
        var view: NSView? = hit
        for _ in 0..<6 {
            guard let current = view else { return false }
            if let text = current as? NSTextField { return !text.isEditable && !text.isSelectable && text.isEnabled && text.action != nil }
            if current is NSTextView { return false }
            if let control = current as? NSControl, control is NSPopUpButton || control is NSSegmentedControl || control is NSButton || control is NSSwitch || control is NSStepper || control is NSColorWell {
                return control.isEnabled
            }
            view = current.superview
        }
        return false
    }
}
