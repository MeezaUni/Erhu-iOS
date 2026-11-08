import Observation
import SwiftUI
import UIKit

/// The search row always has the same height. Scrolling, rather than inserting/removing
/// views, reveals it; this keeps the grid and the user's finger in the same coordinate space.
@MainActor @Observable
final class SectionSearchDrawerState {
    private(set) var ready = false
    private(set) var pinnedOffset: CGFloat = 64
    private(set) var height: CGFloat = 64
    var collapsed: Bool { pinnedOffset >= height - 0.5 }
    @ObservationIgnored private weak var scroll: UIScrollView?
    @ObservationIgnored private var position: CGFloat = 64

    func attach(_ scroll: UIScrollView, height: CGFloat, initiallyRevealed: Bool) {
        self.scroll = scroll
        let target = ready ? position : (initiallyRevealed ? 0 : height)
        self.height = height
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target - scroll.adjustedContentInset.top), animated: false)
        update(scroll)
        ready = true
    }

    func resize(to height: CGFloat) {
        guard height != self.height else { return }
        let oldHeight = self.height
        let target = position >= oldHeight ? position + height - oldHeight : position / max(oldHeight, 1) * height
        self.height = height
        guard let scroll else { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target - scroll.adjustedContentInset.top), animated: false)
        update(scroll)
    }

    func update(_ scroll: UIScrollView) {
        let offset = scroll.contentOffset.y + scroll.adjustedContentInset.top
        guard offset.isFinite else { return }
        position = offset
        let pinned = min(max(offset, 0), height)
        guard pinnedOffset != pinned else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pinnedOffset = pinned }
    }

    func setRevealed(_ revealed: Bool, animated: Bool) {
        guard let scroll else { return }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                                      y: (revealed ? 0 : height) - scroll.adjustedContentInset.top), animated: animated)
    }

    func settle(focused: Bool, animated: Bool) {
        guard position > 0.5, position < height - 0.5 else { return }
        setRevealed(focused || position < height / 2, animated: animated)
    }
}

/// Observes the enclosing vertical scroll view on iOS 17 and later. It never replaces
/// SwiftUI's delegate or gestures. A display link only handles the end of an actual drag.
struct SectionSearchDrawerProbe: UIViewRepresentable {
    let state: SectionSearchDrawerState
    let height: CGFloat
    let initiallyRevealed: Bool
    let focused: () -> Bool
    let reduceMotion: Bool
    let visibilityChanged: (Bool) -> Void

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.state = state; view.height = height; view.initiallyRevealed = initiallyRevealed
        view.focused = focused; view.reduceMotion = reduceMotion; view.visibilityChanged = visibilityChanged
        view.setNeedsLayout()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView {
        var state: SectionSearchDrawerState?
        var height: CGFloat = 64
        var initiallyRevealed = false
        var focused: (() -> Bool)?
        var reduceMotion = false
        var visibilityChanged: ((Bool) -> Void)?
        private weak var scroll: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var displayLink: CADisplayLink?
        private var reportedVisible: Bool?
        private var scheduled = false
        private var attempts = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() }
            else { attempts = 0; scheduleAttach() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            if scroll == nil { scheduleAttach() }
            else if state?.height != height {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.state?.resize(to: self.height)
                }
            }
        }
        private func scheduleAttach() {
            guard window != nil, scroll == nil, !scheduled, attempts < 40 else { return }
            scheduled = true; attempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.attach()
            }
        }
        private func attach() {
            guard window != nil, scroll == nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let found = view as? UIScrollView, found.bounds.height > 0,
                   found.contentSize.height >= found.bounds.height + height - 2 {
                    scroll = found
                    state?.attach(found, height: height, initiallyRevealed: initiallyRevealed)
                    observation = found.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
                        MainActor.assumeIsolated { self?.changed(view) }
                    }
                    found.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
                    changed(found)
                    return
                }
                ancestor = view.superview
            }
            scheduleAttach()
        }
        private func changed(_ scroll: UIScrollView) {
            guard let state else { return }
            state.update(scroll)
            let visible = !state.collapsed
            guard visible != reportedVisible else { return }
            reportedVisible = visible
            visibilityChanged?(visible)
        }
        @objc private func panChanged() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
        @objc private func tick() {
            guard let scroll else { stopDisplayLink(); return }
            if !scroll.isTracking && !scroll.isDragging && !scroll.isDecelerating {
                stopDisplayLink()
                state?.settle(focused: focused?() == true, animated: !reduceMotion)
            }
        }
        private func stopDisplayLink() { displayLink?.invalidate(); displayLink = nil }
        func detach() {
            stopDisplayLink()
            scroll?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged))
            observation = nil; scroll = nil
        }
    }
}
