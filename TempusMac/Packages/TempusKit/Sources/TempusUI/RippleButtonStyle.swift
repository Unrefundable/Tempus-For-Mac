import AppCore
import AppKit
import DesignSystem
import SwiftUI

extension EnvironmentValues {
    /// The surface buttons sit on. Their press ripple is a lighter or darker shade of its color, so
    /// it shows on light and dark themes alike.
    @Entry var rippleSurface: ThemeColorRole = .background
}

extension ButtonStyle where Self == RippleButtonStyle {
    /// For icon buttons, in place of `.borderless`: a circle spreads out from the icon when clicked.
    static var tempusBorderless: RippleButtonStyle {
        RippleButtonStyle(isBounded: false)
    }

    /// For rows, tiles and text, in place of `.plain`: a circle spreads from the click across the
    /// button, kept within its edges.
    static var tempusPlain: RippleButtonStyle {
        RippleButtonStyle(isBounded: true)
    }
}

extension View {
    /// For a `Menu` among buttons. SwiftUI draws it like a `.tempusBorderless` button, so its icon
    /// takes the theme's icon color and ripples like its neighbours. `.borderlessButton` left the
    /// drawing to AppKit, which drew the icon grey with a chevron beside it.
    func tempusMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.tempusBorderless)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// Upstream's Material press ripple: the click shows as a circle of a lighter or darker shade of
/// the surface behind the button, which grows and fades.
struct RippleButtonStyle: ButtonStyle {
    let isBounded: Bool

    func makeBody(configuration: Configuration) -> some View {
        RippleButton(configuration: configuration, isBounded: isBounded)
    }
}

private struct RippleButton: View {
    /// `.borderless` and `.plain` dim a disabled label; a custom style has to do it itself.
    private static let disabledOpacity = 0.4

    let configuration: ButtonStyleConfiguration
    let isBounded: Bool

    @Environment(\.isEnabled) private var isEnabled
    /// Counts presses; each one plays a ripple.
    @State private var pressCount = 0
    /// Where the pointer was last seen over the button: the next ripple's center, for a bounded one.
    @State private var pointer = PointerLocation()

    var body: some View {
        let ripple = RippleLayer(
            pressCount: pressCount,
            isBounded: isBounded,
            origin: pointer.location
        )
        // Only built once the button has been pressed: a grid of tiles scrolling past would
        // otherwise make an AppKit view for every tile that comes into view.
        let hasRipple = pressCount > 0
        configuration.label
            .contentShape(.rect)
            .opacity(isEnabled ? 1 : Self.disabledOpacity)
            // An icon's ripple spreads behind it, so the icon stays crisp. A row's covers it, so a
            // cover or tile image can't hide it.
            .background {
                if hasRipple, !isBounded {
                    ripple
                }
            }
            .overlay {
                if hasRipple, isBounded {
                    ripple
                }
            }
            .onContinuousHover { phase in
                if case let .active(location) = phase {
                    pointer.location = location
                }
            }
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    pressCount += 1
                }
            }
    }
}

/// The pointer's last place over a button. A reference rather than state, so following the pointer
/// doesn't redraw the button on every move: scrolling a grid under a still pointer counts as moving
/// over the tiles, and redrew the one under it every frame. A press redraws the button anyway, and
/// reads the latest place then.
private final class PointerLocation {
    var location: CGPoint?
}

/// The ripple itself: a circle that grows from a point and fades, played once per press. It's a
/// Core Animation layer because SwiftUI's own animations don't run while the mouse button is held
/// on a button, which held each ripple back until the click ended.
private struct RippleLayer: View {
    /// How far an icon's circle reaches past the icon's edges.
    private static let iconPadding: CGFloat = 7
    /// The shade over a dark surface (white) and a light one (black).
    private static let lightenOpacity = 0.22
    private static let darkenOpacity = 0.14

    let pressCount: Int
    let isBounded: Bool
    let origin: CGPoint?

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rippleSurface) private var surface

    var body: some View {
        RippleView(pressCount: pressCount, isBounded: isBounded, origin: origin, color: color)
            // An icon's circle reaches past the icon; a row's is kept within its edges.
            .padding(isBounded ? 0 : -Self.iconPadding)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A lighter shade on a dark surface, a darker one on a light surface.
    private var color: NSColor {
        let surfaceColor = theme.color(for: surface, in: ThemeVariant(colorScheme))
        let isDark = surfaceColor?.isDark ?? (colorScheme == .dark)
        return isDark ? .white.withAlphaComponent(Self.lightenOpacity) : .black.withAlphaComponent(Self.darkenOpacity)
    }
}

/// Plays a ripple each time `pressCount` goes up. It's first built by the press that plays the
/// first ripple, so it plays one for each press up to `pressCount` it hasn't shown yet.
private struct RippleView: NSViewRepresentable {
    let pressCount: Int
    let isBounded: Bool
    let origin: CGPoint?
    let color: NSColor

    final class Coordinator {
        var playedCount: Int

        init(playedCount: Int) {
            self.playedCount = playedCount
        }
    }

    func makeCoordinator() -> Coordinator {
        // Built by a press, which still has to play.
        Coordinator(playedCount: pressCount - 1)
    }

    func makeNSView(context _: Context) -> RippleNSView {
        RippleNSView()
    }

    func updateNSView(_ view: RippleNSView, context: Context) {
        view.isBounded = isBounded
        guard pressCount != context.coordinator.playedCount else { return }
        context.coordinator.playedCount = pressCount
        view.ripple(from: isBounded ? origin : nil, color: color)
    }
}

private final class RippleNSView: NSView {
    private static let cornerRadius = Theme.Radius.artworkSmall
    private static let growDuration: CFTimeInterval = 0.3
    private static let fadeDuration: CFTimeInterval = 0.35
    /// The fade starts once the circle has grown this far through its growth.
    private static let fadeStartShare = 0.5
    /// Where a ripple starts, as a part of its full size.
    private static let startScale: CGFloat = 0.25

    var isBounded = false {
        didSet {
            layer?.masksToBounds = isBounded
            layer?.cornerRadius = isBounded ? Self.cornerRadius : 0
        }
    }

    override var isFlipped: Bool {
        true // the same top-left origin as SwiftUI's pointer location
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// A ripple asked for before the view had a size: it's built by the press it plays for, which
    /// happens before SwiftUI lays it out.
    private var pending: (point: CGPoint?, color: NSColor)?

    override func hitTest(_: NSPoint) -> NSView? {
        nil // never takes the button's clicks
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let pending, !bounds.isEmpty else { return }
        self.pending = nil
        ripple(from: pending.point, color: pending.color)
    }

    /// A circle from `point` (the middle when nil) that grows to cover the view, then fades.
    func ripple(from point: CGPoint?, color: NSColor) {
        guard !bounds.isEmpty else {
            pending = (point, color)
            return
        }
        guard let layer else { return }
        let center = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = isBounded ? Self.farthestCornerDistance(from: center, in: bounds.size)
            : max(bounds.width, bounds.height) / 2
        let circle = CAShapeLayer()
        circle.path = CGPath(
            ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
            transform: nil
        )
        circle.position = center
        circle.fillColor = color.cgColor
        circle.contentsScale = window?.backingScaleFactor ?? 2
        circle.opacity = 0 // where it ends, so it doesn't reappear once the animation is done
        layer.addSublayer(circle)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = Self.startScale
        grow.toValue = 1
        grow.duration = Self.growDuration
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fadeStart = Self.growDuration * Self.fadeStartShare
        let total = fadeStart + Self.fadeDuration
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: fadeStart / total), 1]
        fade.duration = total

        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = total
        circle.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak circle] in
            circle?.removeFromSuperlayer()
        }
    }

    private static func farthestCornerDistance(from point: CGPoint, in size: CGSize) -> CGFloat {
        let across = max(point.x, size.width - point.x)
        let down = max(point.y, size.height - point.y)
        return (across * across + down * down).squareRoot()
    }
}
