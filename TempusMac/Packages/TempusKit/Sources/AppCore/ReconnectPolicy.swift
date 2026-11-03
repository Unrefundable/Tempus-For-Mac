/// When an offline session tries its server again. A round is a fixed list of waits, one attempt
/// after each, so it always ends: the server answers, refuses the account, or the waits run out.
/// After that only the Reconnect button or a change of network starts another round.
public struct ReconnectPolicy: Sendable, Equatable {
    /// The wait before each attempt, in order.
    public let delays: [Duration]

    public init(delays: [Duration]) {
        self.delays = delays
    }

    /// Quick at first, for a network that is still coming up at launch or after waking, then
    /// backing off: six attempts over about a minute and a half.
    public static let standard = Self(delays: [2, 4, 8, 15, 30, 30].map { .seconds($0) })
}
