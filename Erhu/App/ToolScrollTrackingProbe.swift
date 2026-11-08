import SwiftUI
import UIKit

/// Lists use UIKit collection/table scrolling. Observe their real scroll view without
/// replacing its delegate, gestures or data source; a display link exists only during a drag.
struct ToolScrollTrackingProbe: UIViewRepresentable {
    var active: () -> Bool
    var consume: (CGFloat) -> Void
    var settle: () -> Void
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.active = active; view.consume = consume; view.settle = settle
        view.setNeedsLayout()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView {
        var active: (() -> Bool)?
        var consume: ((CGFloat) -> Void)?
        var settle: (() -> Void)?
        private weak var scroll: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var displayLink: CADisplayLink?
        private var lastOffset: CGFloat?
        private var attachAttempts = 0
        private var attachScheduled = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() }
            else {
                attachAttempts = 0
                DispatchQueue.main.async { [weak self] in self?.attach() }
            }
        }
        override func layoutSubviews() { super.layoutSubviews(); if scroll == nil { attach() } }

        private func attach() {
            guard window != nil, scroll == nil else { return }
            var parent = superview
            while let root = parent {
                let candidates = lists(in: root)
                if let found = candidates.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                    scroll = found
                    lastOffset = offset(found)
                    found.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
                    observation = found.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
                        MainActor.assumeIsolated { self?.changed(view) }
                    }
                    return
                }
                parent = root.superview
            }
            // SwiftUI can mount its list after the overlay's first layout pass.
            guard !attachScheduled, attachAttempts < 20 else { return }
            attachAttempts += 1; attachScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.attachScheduled = false
                self.attach()
            }
        }
        private func lists(in view: UIView) -> [UIScrollView] {
            // SwiftUI can hide its UIKit containers from accessibility while exposing a
            // separate accessibility tree. That flag does not mean the list is offscreen.
            guard !view.isHidden, view.alpha > 0.01, view.layer.opacity > 0.01 else { return [] }
            if let scroll = view as? UIScrollView, scroll.bounds.width > 100, scroll.bounds.height > 100, let window {
                let visible = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
                return !visible.isNull && visible.width > 100 && visible.height > 100 ? [scroll] : []
            }
            return view.subviews.flatMap { lists(in: $0) }
        }
        private func offset(_ view: UIScrollView) -> CGFloat {
            let end = max(view.contentSize.height + view.adjustedContentInset.top + view.adjustedContentInset.bottom - view.bounds.height, 0)
            return (view.contentOffset.y + view.adjustedContentInset.top).clamped(0, end)
        }
        private func changed(_ view: UIScrollView) {
            let next = offset(view)
            defer { lastOffset = next }
            guard active?() == true, view.isDragging || view.isDecelerating, let previous = lastOffset else { return }
            consume?(next - previous)
        }
        @objc private func panChanged() {
            guard let scroll else { return }
            if scroll.panGestureRecognizer.state == .began { lastOffset = offset(scroll) }
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick))
                displayLink = link
                link.add(to: .main, forMode: .common)
            }
        }
        @objc private func tick() {
            guard let scroll else { displayLink?.invalidate(); displayLink = nil; return }
            if !scroll.isTracking && !scroll.isDragging && !scroll.isDecelerating {
                displayLink?.invalidate(); displayLink = nil
                if active?() == true { settle?() }
            }
        }
        func detach() {
            displayLink?.invalidate(); displayLink = nil
            scroll?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged))
            scroll = nil; observation = nil; lastOffset = nil
        }
    }
}
