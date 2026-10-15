import SwiftUI
import UIKit
import ShikeCore

struct CalendarTimelineGeometry {
    let days: [Date]
    let columnWidth: CGFloat
    let hourHeight: CGFloat
    let timeZone: TimeZone
    var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = timeZone; return value }
    func dayIndex(at point: CGPoint) -> Int { min(days.count - 1, max(0, Int(floor(point.x / max(1, columnWidth))))) }
    func date(at point: CGPoint) -> Date {
        let day = days[dayIndex(at: point)]
        let end = calendar.date(byAdding: .day, value: 1, to: day)!
        let seconds = (Double(point.y / hourHeight) * 4).rounded() * 900
        return day.addingTimeInterval(min(end.timeIntervalSince(day) - 900, max(0, seconds)))
    }
    func moving(_ event: CalendarEventSnapshot, from origin: CGPoint, to point: CGPoint) -> DateInterval {
        let dayDelta = dayIndex(at: point) - dayIndex(at: origin)
        if event.allDay {
            var source = calendar; source.timeZone = TimeZone(identifier: event.timeZone) ?? timeZone
            return DateInterval(start: source.date(byAdding: .day, value: dayDelta, to: event.start)!,
                                end: source.date(byAdding: .day, value: dayDelta, to: event.end)!)
        }
        let delta = (Double((point.y - origin.y) / hourHeight) * 4).rounded() * 900
        let start = calendar.date(byAdding: .day, value: dayDelta, to: event.start)!.addingTimeInterval(delta)
        return DateInterval(start: start, duration: event.end.timeIntervalSince(event.start))
    }
}

struct CalendarDragSelection {
    let origin: CGPoint
    let event: CalendarEventSnapshot?
    let allDay: Bool
    let initial: DateInterval
    var interval: DateInterval
}

/// Observe a hold on this canvas without adding a hit-testing layer above event buttons.
/// A short swipe remains a scroll; once a hold begins, it owns the drag until release.
struct CalendarHoldInteraction: UIViewRepresentable {
    let action: (UIGestureRecognizer.State, CGPoint) -> Void
    func makeUIView(context: Context) -> Canvas { Canvas() }
    func updateUIView(_ view: Canvas, context: Context) { view.action = action }
    static func dismantleUIView(_ view: Canvas, coordinator: ()) { view.detach() }
    final class Canvas: UIView, UIGestureRecognizerDelegate {
        var action: ((UIGestureRecognizer.State, CGPoint) -> Void)?
        private weak var attachedWindow: UIWindow?
        private var ticker: CADisplayLink?
        private var pausedScrollViews: [UIScrollView] = []
        private lazy var hold: UILongPressGestureRecognizer = {
            let value = UILongPressGestureRecognizer(target: self, action: #selector(changed))
            value.minimumPressDuration = 0.45; value.allowableMovement = 10
            value.delegate = self; value.cancelsTouchesInView = true
            return value
        }()
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            if let window { window.addGestureRecognizer(hold); attachedWindow = window }
        }
        func detach() { ticker?.invalidate(); ticker = nil; resumeScrolling(); attachedWindow?.removeGestureRecognizer(hold); attachedWindow = nil }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard window != nil, bounds.contains(touch.location(in: self)),
                  window?.rootViewController?.presentedViewController == nil else { return false }
            var parent: UIView? = self
            while let view = parent {
                if view.isHidden || view.alpha < 0.01 { return false }
                if view.clipsToBounds && !view.bounds.contains(touch.location(in: view)) { return false }
                parent = view.superview
            }
            return true
        }
        @objc private func changed() {
            if hold.state == .began {
                var ancestor = superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView, scroll.panGestureRecognizer.isEnabled {
                        scroll.panGestureRecognizer.isEnabled = false; pausedScrollViews.append(scroll)
                    }
                    ancestor = view.superview
                }
            }
            action?(hold.state, hold.location(in: self))
            if hold.state == .began {
                ticker = CADisplayLink(target: self, selector: #selector(autoScroll))
                ticker?.add(to: .main, forMode: .common)
            } else if [.ended, .cancelled, .failed].contains(hold.state) {
                ticker?.invalidate(); ticker = nil
                resumeScrolling()
            }
        }
        private func resumeScrolling() {
            pausedScrollViews.forEach { $0.panGestureRecognizer.isEnabled = true }; pausedScrollViews.removeAll()
        }
        @objc private func autoScroll(_ link: CADisplayLink) {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 20 {
                    let point = hold.location(in: scroll)
                    let y = point.y - scroll.bounds.minY
                    let speed: CGFloat = y < 48 ? -min(260, (48 - y) * 5) : y > scroll.bounds.height - 48 ? min(260, (y - scroll.bounds.height + 48) * 5) : 0
                    let lower = -scroll.adjustedContentInset.top
                    let upper = max(lower, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    let offset = min(upper, max(lower, scroll.contentOffset.y + speed * CGFloat(link.targetTimestamp - link.timestamp)))
                    if abs(offset - scroll.contentOffset.y) > 0.01 {
                        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
                        action?(.changed, hold.location(in: self))
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
