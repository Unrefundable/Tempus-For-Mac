import SwiftUI

public extension EnvironmentValues {
    /// True while the player is audibly playing, so the playing track's bars dance; paused, they
    /// stand still.
    @Entry var isPlaybackActive = false
}

/// The playing track's mark: upstream's three-bar equalizer icon, its bars rising and falling while
/// music plays. It draws at `tempusIconSize`, in `tempusIconColor` when the theme sets one and the
/// foreground style otherwise, like `TempusIconImage`.
public struct NowPlayingBars: View {
    /// Where upstream's `ic_eq` draws its bars, as parts of the icon's side: three bars a sixth wide
    /// with a twelfth between them, inset a sixth from the edges.
    nonisolated enum Geometry {
        static let inset: CGFloat = 1.0 / 6
        static let barWidth: CGFloat = 1.0 / 6
        static let gap: CGFloat = 1.0 / 12
        /// The tallest bar, as part of the icon's side.
        static let maxHeight: CGFloat = 2.0 / 3
    }

    /// The icon's own bar heights, shown while paused, as parts of `Geometry.maxHeight`.
    nonisolated static let restingLevels: [CGFloat] = [0.5, 1, 0.69]
    /// The lowest a bar falls while playing, so it never vanishes.
    nonisolated static let minimumLevel: CGFloat = 0.2
    /// Each bar's speed (radians a second) and starting phase, unrelated so the bars don't move
    /// in step.
    private nonisolated static let motions: [(speed: Double, phase: Double)] = [(7.3, 0), (9.1, 1.7), (6.2, 3.1)]
    /// Smooth enough to read as motion without redrawing every display frame.
    private static let frameInterval: TimeInterval = 1.0 / 30

    @Environment(\.tempusIconSize) private var size
    @Environment(\.isPlaybackActive) private var isPlaybackActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        let animates = isPlaybackActive && !reduceMotion
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !animates)) { timeline in
            let levels = animates
                ? Self.levels(at: timeline.date.timeIntervalSinceReferenceDate)
                : Self.restingLevels
            Canvas { context, canvasSize in
                for (index, level) in levels.enumerated() {
                    context.fill(Path(Self.barRect(index: index, level: level, in: canvasSize)), with: .foreground)
                }
            }
        }
        .frame(width: size, height: size)
        .tempusIconTinted()
        .accessibilityElement()
        .accessibilityLabel(Text("Now playing"))
        .accessibilityAddTraits(.isImage)
    }

    /// The bars' heights `time` seconds in, each between `minimumLevel` and 1.
    nonisolated static func levels(at time: TimeInterval) -> [CGFloat] {
        motions.map { motion in
            let wave = abs(sin(time * motion.speed / 2 + motion.phase))
            return minimumLevel + (1 - minimumLevel) * CGFloat(wave)
        }
    }

    /// Bar `index` at `level`, standing on the icon's baseline.
    nonisolated static func barRect(index: Int, level: CGFloat, in size: CGSize) -> CGRect {
        let side = min(size.width, size.height)
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        let height = side * Geometry.maxHeight * min(max(level, 0), 1)
        let baseline = origin.y + side * (1 - Geometry.inset)
        let left = origin.x + side * (Geometry.inset + CGFloat(index) * (Geometry.barWidth + Geometry.gap))
        return CGRect(x: left, y: baseline - height, width: side * Geometry.barWidth, height: height)
    }
}
