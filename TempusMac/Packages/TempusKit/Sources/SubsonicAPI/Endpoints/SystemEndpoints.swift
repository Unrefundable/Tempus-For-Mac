import Foundation

// System, scanning and lyrics.

public extension SubsonicRequest where Response == ServerInfo {
    /// Checks connectivity and credentials, and reports the server's identity.
    static var ping: Self {
        Self(method: "ping")
    }
}

public extension SubsonicRequest where Response == [OpenSubsonicExtension] {
    /// Only meaningful when `ServerInfo.isOpenSubsonic` is true.
    static var openSubsonicExtensions: Self {
        Self(method: "getOpenSubsonicExtensions", elementPath: ["openSubsonicExtensions"])
    }
}

public extension SubsonicRequest where Response == ScanStatus {
    static var scanStatus: Self {
        Self(method: "getScanStatus", elementPath: ["scanStatus"])
    }

    static var startScan: Self {
        Self(method: "startScan", elementPath: ["scanStatus"])
    }
}

public extension SubsonicRequest where Response == Lyrics? {
    /// Classic lookup by artist and title. Prefer `lyrics(songID:)` when the server has `songLyrics`.
    static func lyrics(artist: String, title: String) -> Self {
        Self(method: "getLyrics", parameters: query(("artist", artist), ("title", title)), elementPath: ["lyrics"])
    }
}

public extension SubsonicRequest where Response == [StructuredLyrics] {
    /// OpenSubsonic `songLyrics` extension.
    static func lyrics(songID: String) -> Self {
        Self(
            method: "getLyricsBySongId",
            parameters: query(("id", songID)),
            elementPath: ["lyricsList", "structuredLyrics"]
        )
    }
}
