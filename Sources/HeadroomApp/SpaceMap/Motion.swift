import SwiftUI

/// The Space Map's motion in one place. Springs start from where things are and can be
/// interrupted; they have no overshoot unless something was moved by hand. Under Reduce
/// Motion, travel becomes a short fade.
enum Motion {
    /// Tiles moving and resizing as the list changes: filters, sizes arriving, things leaving.
    static let layout = Animation.spring(response: 0.42, dampingFraction: 0.9)
    /// Selection and hover: quick, so it feels like a response, not an animation.
    static let respond = Animation.easeOut(duration: 0.16)
    /// Things arriving that you didn't cause: contents behind the glass, badges, measured sizes.
    static let arrive = Animation.easeOut(duration: 0.35)
    /// The fade that replaces travel under Reduce Motion.
    static let fade = Animation.easeInOut(duration: 0.2)

    static func layout(reduced: Bool) -> Animation { reduced ? fade : layout }
    static func travel(reduced: Bool) -> Animation { reduced ? fade : PlanTray.travel }
}

extension AnyTransition {
    /// Badges and chips: grow in from a little smaller.
    static var pop: AnyTransition { .scale(scale: 0.7).combined(with: .opacity) }
}
