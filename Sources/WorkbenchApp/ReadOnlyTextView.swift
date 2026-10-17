import AppKit
import SwiftUI

struct ReadOnlyTextView: NSViewRepresentable {
    var text: String
    var foregroundColor: NSColor = .labelColor
    var backgroundColor: NSColor = .textBackgroundColor
    var pointSize: CGFloat = 11
    var accessibilityName = "文本预览"

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 420, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.font = .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        view.textColor = foregroundColor; view.backgroundColor = backgroundColor
        view.setAccessibilityLabel(accessibilityName)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        let origin = scroll.contentView.bounds.origin
        let followingTail = scroll.contentView.bounds.maxY >= view.bounds.maxY - 24
        let selection = view.selectedRange()
        view.string = text
        let length = text.utf16.count
        view.setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - min(selection.location, length)))))
        if followingTail { view.scrollRangeToVisible(NSRange(location: length, length: 0)) }
        else { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
    }
}
