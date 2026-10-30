import Foundation

/// Query items in order, skipping parameters whose value is nil.
func query(_ pairs: (String, (any CustomStringConvertible)?)...) -> [URLQueryItem] {
    pairs.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0.description) } }
}

/// One query item per value, for parameters the API accepts repeatedly (`id`, `songId`, ...).
func repeated(_ name: String, _ values: [some CustomStringConvertible]) -> [URLQueryItem] {
    values.map { URLQueryItem(name: name, value: $0.description) }
}

/// Subsonic times are milliseconds since 1970.
func milliseconds(_ date: Date?) -> Int64? {
    date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
}
