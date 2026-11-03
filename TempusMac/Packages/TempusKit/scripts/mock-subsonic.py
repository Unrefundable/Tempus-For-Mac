#!/usr/bin/env python3
"""A small Subsonic/OpenSubsonic server for trying Tempus end to end without a real one.

Serves a fixed library of generated sine-tone tracks, a podcast, radio stations, playlists,
shares, stars, bookmarks and the play queue, all kept in memory. Every request is logged to
stdout (without credentials) so a test can check what the app sent.

    scripts/mock-subsonic.py [--port 4533] [--media DIR]

Test account (not a real secret): username "tempus", password "mock-pass".
Point Tempus at http://127.0.0.1:4533. Needs ffmpeg to generate the audio on first run.
Binds to 127.0.0.1 only.
"""

import argparse
import hashlib
import json
import os
import struct
import subprocess
import sys
import threading
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

USER, PASSWORD = "tempus", "mock-pass"
LOCK = threading.Lock()

ARTISTS = [
    {"id": "ar1", "name": "The Sine Waves", "albums": ["al1", "al2"]},
    {"id": "ar2", "name": "Square Society", "albums": ["al3"]},
]
ALBUMS = {
    "al1": {"name": "Pure Tones", "artist": "ar1", "year": 2019, "genre": "Electronic", "folder": "1"},
    "al2": {"name": "Harmonics", "artist": "ar1", "year": 2003, "genre": "Ambient", "folder": "1"},
    "al3": {"name": "Duty Cycles", "artist": "ar2", "year": 1995, "genre": "Rock", "folder": "2"},
}
# id, album, track, title, frequency, seconds, suffix
TRACKS = [
    ("s1", "al1", 1, "A Above Middle C", 440, 20, "flac"),
    ("s2", "al1", 2, "Low Hum", 220, 20, "mp3"),
    ("s3", "al1", 3, "High Whistle", 880, 20, "mp3"),
    ("s4", "al2", 1, "Fifth", 330, 20, "mp3"),
    ("s5", "al2", 2, "Long Drone", 165, 660, "mp3"),
    ("s6", "al3", 1, "Square One", 523, 20, "mp3"),
    ("s7", "al3", 2, "Square Two", 587, 20, "mp3"),
]
PODCAST_EPISODES = [("pe1", "pod1", "Episode 1: Tones", 600), ("pe2", "pod2", "Episode 2: Not downloaded", 300)]

STATE = {
    "starred": {"s1": "2026-10-01T10:00:00Z", "al2": "2026-10-01T10:00:00Z", "ar2": "2026-10-01T10:00:00Z"},
    "ratings": {},
    "playlists": {"pl1": {"name": "Road Trip", "songs": ["s1", "s6", "s3"], "created": "2026-09-01T10:00:00Z"}},
    "bookmarks": {},
    "queue": None,
    "radios": {"r1": {"name": "Mock FM", "streamUrl": "https://radio.example.invalid/live", "homePageUrl": None}},
    "shares": {},
    "podcasts": True,
}


def song(track_id):
    t = next(t for t in TRACKS if t[0] == track_id)
    tid, album_id, number, title, _, seconds, suffix = t
    album = ALBUMS[album_id]
    artist = next(a for a in ARTISTS if a["id"] == album["artist"])
    entry = {
        "id": tid, "parent": "d-" + album_id, "isDir": False, "title": title, "album": album["name"],
        "artist": artist["name"], "track": number, "year": album["year"], "genre": album["genre"],
        "coverArt": album_id, "size": 1000, "contentType": "audio/flac" if suffix == "flac" else "audio/mpeg",
        "suffix": suffix, "duration": seconds, "bitRate": 900 if suffix == "flac" else 128, "path": f"{artist['name']}/{album['name']}/{number:02d} {title}.{suffix}",
        "albumId": album_id, "artistId": artist["id"], "type": "music", "discNumber": 1,
        "playCount": 3, "displayAlbumArtist": artist["name"],
        "replayGain": {"trackGain": -6.0, "albumGain": -5.0, "trackPeak": 0.9, "albumPeak": 0.95},
    }
    if tid in STATE["starred"]:
        entry["starred"] = STATE["starred"][tid]
    if tid in STATE["ratings"]:
        entry["userRating"] = STATE["ratings"][tid]
    return entry


def album_json(album_id, with_songs=False):
    a = ALBUMS[album_id]
    artist = next(x for x in ARTISTS if x["id"] == a["artist"])
    songs = [t[0] for t in TRACKS if t[1] == album_id]
    out = {
        "id": album_id, "name": a["name"], "artist": artist["name"], "artistId": artist["id"], "coverArt": album_id,
        "songCount": len(songs), "duration": sum(t[5] for t in TRACKS if t[1] == album_id), "year": a["year"],
        "genre": a["genre"], "created": "2026-01-0%dT10:00:00Z" % (int(album_id[-1])), "playCount": 5,
        "displayArtist": artist["name"],
    }
    if album_id in STATE["starred"]:
        out["starred"] = STATE["starred"][album_id]
    if with_songs:
        out["song"] = [song(s) for s in songs]
    return out


def artist_json(artist, with_albums=False):
    out = {"id": artist["id"], "name": artist["name"], "coverArt": artist["albums"][0], "albumCount": len(artist["albums"])}
    if artist["id"] in STATE["starred"]:
        out["starred"] = STATE["starred"][artist["id"]]
    if with_albums:
        out["album"] = [album_json(a) for a in artist["albums"]]
    return out


def playlist_json(pid, with_songs=False):
    p = STATE["playlists"][pid]
    out = {"id": pid, "name": p["name"], "owner": USER, "public": False, "songCount": len(p["songs"]),
           "duration": sum(song(s)["duration"] for s in p["songs"]), "created": p["created"],
           "changed": p["created"], "coverArt": "pl-" + pid}
    if with_songs:
        out["entry"] = [song(s) for s in p["songs"]]
    return out


def podcast_json(with_episodes):
    channel = {"id": "pc1", "url": "https://podcast.example.invalid/feed.xml", "title": "Mock Cast",
               "description": "Two episodes about <b>tones</b>.", "coverArt": "pc1", "status": "completed"}
    if with_episodes:
        channel["episode"] = [{
            "id": eid, "streamId": sid if eid == "pe1" else None, "channelId": "pc1", "title": title,
            "description": "An episode", "publishDate": "2026-10-2%dT10:00:00Z" % i, "status": "completed" if eid == "pe1" else "skipped",
            "duration": seconds, "suffix": "mp3", "contentType": "audio/mpeg", "coverArt": "pc1",
        } for i, (eid, sid, title, seconds) in enumerate(PODCAST_EPISODES)]
        channel["episode"] = [{k: v for k, v in e.items() if v is not None} for e in channel["episode"]]
    return channel


def png(color):
    """A 64x64 solid PNG, made with the standard library only."""
    width = height = 64
    raw = b"".join(b"\x00" + bytes(color) * width for _ in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class Handler(BaseHTTPRequestHandler):
    media = "."

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.handle_request(parse_qs(urlparse(self.path).query))

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        params = parse_qs(urlparse(self.path).query)
        for key, values in parse_qs(body).items():
            params.setdefault(key, []).extend(values)
        self.handle_request(params)

    def handle_request(self, params):
        method = urlparse(self.path).path.rsplit("/", 1)[-1].removesuffix(".view")
        one = lambda name, default=None: (params.get(name) or [default])[0]
        shown = {k: v for k, v in params.items() if k not in ("t", "s", "p", "u")}
        print(json.dumps({"time": round(time.time(), 3), "method": method, "params": shown}), flush=True)
        if not self.authorised(params):
            return self.send_json({"status": "failed", "error": {"code": 40, "message": "Wrong username or password"}})
        with LOCK:
            try:
                handler = getattr(self, "api_" + method, None)
                if handler is None:
                    return self.send_json({"status": "failed", "error": {"code": 0, "message": f"{method} not mocked"}})
                result = handler(one, params)
            except KeyError:
                return self.send_json({"status": "failed", "error": {"code": 70, "message": "Not found"}})
        if isinstance(result, tuple):
            return self.send_bytes(*result)
        if result == 501:
            self.send_response(501)
            self.end_headers()
            return
        self.send_json({"status": "ok", **(result or {})})

    def authorised(self, params):
        user = (params.get("u") or [""])[0]
        if user != USER:
            return False
        if "t" in params and "s" in params:
            expected = hashlib.md5((PASSWORD + params["s"][0]).encode()).hexdigest()
            return params["t"][0] == expected
        password = (params.get("p") or [""])[0]
        if password.startswith("enc:"):
            password = bytes.fromhex(password[4:]).decode()
        return password == PASSWORD

    def send_json(self, payload):
        body = json.dumps({"subsonic-response": {"version": "1.16.1", "type": "mock", "serverVersion": "1.0",
                                                 "openSubsonic": True, **payload}}).encode()
        self.send_bytes(body, "application/json")

    def send_bytes(self, body, content_type, status=200):
        start, end, total = 0, len(body) - 1, len(body)
        header = self.headers.get("Range")
        if header and header.startswith("bytes=") and content_type.startswith("audio"):
            first, _, last = header[6:].partition("-")
            start = int(first or 0)
            end = int(last) if last else total - 1
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        try:
            self.wfile.write(body[start:end + 1])
        except (BrokenPipeError, ConnectionResetError):
            pass

    # System
    def api_ping(self, one, params):
        return {}

    def api_getLicense(self, one, params):
        return {"license": {"valid": True}}

    def api_getOpenSubsonicExtensions(self, one, params):
        return {"openSubsonicExtensions": [{"name": "songLyrics", "versions": [1]}]}

    def api_getMusicFolders(self, one, params):
        return {"musicFolders": {"musicFolder": [{"id": "1", "name": "Tones"}, {"id": "2", "name": "Squares"}]}}

    # Browsing
    def api_getArtists(self, one, params):
        folder = one("musicFolderId")
        artists = [a for a in ARTISTS if folder is None or any(ALBUMS[x]["folder"] == folder for x in a["albums"])]
        index = {}
        for a in artists:
            index.setdefault(a["name"].removeprefix("The ")[0], []).append(artist_json(a))
        return {"artists": {"ignoredArticles": "The", "index": [{"name": k, "artist": v} for k, v in sorted(index.items())]}}

    def api_getArtist(self, one, params):
        return {"artist": artist_json(next(a for a in ARTISTS if a["id"] == one("id")) if any(a["id"] == one("id") for a in ARTISTS) else {}["x"], True)}

    def api_getArtistInfo2(self, one, params):
        others = [artist_json(a) for a in ARTISTS if a["id"] != one("id")]
        return {"artistInfo2": {"biography": "A mock artist made of pure tones. <a href=\"https://example.invalid\">More</a>", "similarArtist": others}}

    def api_getAlbum(self, one, params):
        return {"album": album_json(one("id") if one("id") in ALBUMS else {}["x"], True)}

    def api_getSong(self, one, params):
        return {"song": song(one("id"))}

    def api_getGenres(self, one, params):
        genres = {}
        for t in TRACKS:
            g = ALBUMS[t[1]]["genre"]
            genres.setdefault(g, {"value": g, "songCount": 0, "albumCount": 0})["songCount"] += 1
        for a in ALBUMS.values():
            genres[a["genre"]]["albumCount"] += 1
        return {"genres": {"genre": list(genres.values())}}

    def api_getIndexes(self, one, params):
        return {"indexes": {"lastModified": 0, "ignoredArticles": "The", "index": [
            {"name": "S", "artist": [{"id": "d-" + a["id"], "name": a["name"]} for a in ARTISTS]}]}}

    def api_getMusicDirectory(self, one, params):
        folder = one("id")
        if folder.startswith("d-ar"):
            artist = next(a for a in ARTISTS if "d-" + a["id"] == folder)
            children = [{"id": "d-" + x, "parent": folder, "isDir": True, "title": ALBUMS[x]["name"], "coverArt": x} for x in artist["albums"]]
            return {"directory": {"id": folder, "name": artist["name"], "child": children}}
        album_id = folder.removeprefix("d-")
        return {"directory": {"id": folder, "name": ALBUMS[album_id]["name"], "child": [song(t[0]) for t in TRACKS if t[1] == album_id]}}

    # Lists
    def api_getAlbumList2(self, one, params):
        kind, folder = one("type"), one("musicFolderId")
        size, offset = int(one("size", 10)), int(one("offset", 0))
        ids = [a for a in ALBUMS if folder is None or ALBUMS[a]["folder"] == folder]
        if kind == "starred":
            ids = [a for a in ids if a in STATE["starred"]]
        elif kind == "byGenre":
            ids = [a for a in ids if ALBUMS[a]["genre"] == one("genre")]
        elif kind == "byYear":
            low, high = sorted((int(one("fromYear")), int(one("toYear"))))
            ids = [a for a in ids if low <= ALBUMS[a]["year"] <= high]
        elif kind in ("alphabeticalByName", "alphabeticalByArtist"):
            ids.sort(key=lambda a: ALBUMS[a]["name"])
        elif kind == "newest":
            ids.reverse()
        return {"albumList2": {"album": [album_json(a) for a in ids[offset:offset + size]]}}

    def api_getRandomSongs(self, one, params):
        folder = one("musicFolderId")
        ids = [t[0] for t in TRACKS if folder is None or ALBUMS[t[1]]["folder"] == folder]
        return {"randomSongs": {"song": [song(s) for s in ids[: int(one("size", 10))]]}}

    def api_getSongsByGenre(self, one, params):
        return {"songsByGenre": {"song": [song(t[0]) for t in TRACKS if ALBUMS[t[1]]["genre"] == one("genre")]}}

    def api_getSimilarSongs(self, one, params):
        return {"similarSongs": {"song": [song(t[0]) for t in TRACKS if t[0] != one("id")][:4]}}

    def api_getSimilarSongs2(self, one, params):
        return {"similarSongs2": {"song": [song(t[0]) for t in TRACKS][:4]}}

    def api_getTopSongs(self, one, params):
        artist = next((a for a in ARTISTS if a["name"] == one("artist")), None)
        ids = [t[0] for t in TRACKS if artist and t[1] in artist["albums"]]
        return {"topSongs": {"song": [song(s) for s in ids]}}

    def api_getStarred2(self, one, params):
        starred = STATE["starred"]
        return {"starred2": {
            "artist": [artist_json(a) for a in ARTISTS if a["id"] in starred],
            "album": [album_json(a) for a in ALBUMS if a in starred],
            "song": [song(t[0]) for t in TRACKS if t[0] in starred],
        }}

    def api_search3(self, one, params):
        query = one("query", "").strip('"').lower()
        return {"searchResult3": {
            "artist": [artist_json(a) for a in ARTISTS if query in a["name"].lower()],
            "album": [album_json(a) for a in ALBUMS if query in ALBUMS[a]["name"].lower()],
            "song": [song(t[0]) for t in TRACKS if query in t[3].lower()],
        }}

    # Annotation
    def api_star(self, one, params):
        for key in ("id", "albumId", "artistId"):
            for value in params.get(key, []):
                STATE["starred"][value] = "2026-11-02T10:00:00Z"
        return {}

    def api_unstar(self, one, params):
        for key in ("id", "albumId", "artistId"):
            for value in params.get(key, []):
                STATE["starred"].pop(value, None)
        return {}

    def api_setRating(self, one, params):
        STATE["ratings"][one("id")] = int(one("rating"))
        return {}

    def api_scrobble(self, one, params):
        return {}

    # Bookmarks and queue
    def api_getBookmarks(self, one, params):
        return {"bookmarks": {"bookmark": [
            {"entry": song(i) if not i.startswith("pod") else self.episode_song(i), "position": b["position"],
             "username": USER, "created": b["changed"], "changed": b["changed"]}
            for i, b in STATE["bookmarks"].items()]}}

    def episode_song(self, stream_id):
        eid, sid, title, seconds = next(e for e in PODCAST_EPISODES if e[1] == stream_id)
        return {"id": sid, "title": title, "album": "Mock Cast", "coverArt": "pc1", "duration": seconds, "type": "podcast", "suffix": "mp3"}

    def api_createBookmark(self, one, params):
        STATE["bookmarks"][one("id")] = {"position": int(one("position")), "changed": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        return {}

    def api_deleteBookmark(self, one, params):
        STATE["bookmarks"].pop(one("id"), None)
        return {}

    def api_getPlayQueue(self, one, params):
        queue = STATE["queue"]
        if not queue:
            return {}
        return {"playQueue": {"entry": [song(s) for s in queue["ids"]], "current": queue["current"],
                              "position": queue["position"], "username": USER, "changed": "2026-11-02T10:00:00Z", "changedBy": "mock"}}

    def api_savePlayQueue(self, one, params):
        STATE["queue"] = {"ids": params.get("id", []), "current": one("current"), "position": int(one("position", 0))}
        return {}

    # Playlists
    def api_getPlaylists(self, one, params):
        return {"playlists": {"playlist": [playlist_json(p) for p in STATE["playlists"]]}}

    def api_getPlaylist(self, one, params):
        return {"playlist": playlist_json(one("id") if one("id") in STATE["playlists"] else {}["x"], True)}

    def api_createPlaylist(self, one, params):
        pid = "pl" + uuid.uuid4().hex[:6]
        STATE["playlists"][pid] = {"name": one("name"), "songs": params.get("songId", []), "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        return {"playlist": playlist_json(pid, True)}

    def api_updatePlaylist(self, one, params):
        playlist = STATE["playlists"][one("playlistId")]
        if one("name"):
            playlist["name"] = one("name")
        remove = {int(i) for i in params.get("songIndexToRemove", [])}
        playlist["songs"] = [s for i, s in enumerate(playlist["songs"]) if i not in remove] + params.get("songIdToAdd", [])
        return {}

    def api_deletePlaylist(self, one, params):
        del STATE["playlists"][one("id")]
        return {}

    # Radio
    def api_getInternetRadioStations(self, one, params):
        return {"internetRadioStations": {"internetRadioStation": [
            {"id": i, **{k: v for k, v in r.items() if v}} for i, r in STATE["radios"].items()]}}

    def api_createInternetRadioStation(self, one, params):
        STATE["radios"]["r" + uuid.uuid4().hex[:6]] = {"name": one("name"), "streamUrl": one("streamUrl"), "homePageUrl": one("homepageUrl")}
        return {}

    def api_updateInternetRadioStation(self, one, params):
        STATE["radios"][one("id")] = {"name": one("name"), "streamUrl": one("streamUrl"), "homePageUrl": one("homepageUrl")}
        return {}

    def api_deleteInternetRadioStation(self, one, params):
        del STATE["radios"][one("id")]
        return {}

    # Podcasts
    def api_getPodcasts(self, one, params):
        return {"podcasts": {"channel": [podcast_json(one("includeEpisodes", "true") != "false")]}}

    def api_getNewestPodcasts(self, one, params):
        return {"newestPodcasts": {"episode": podcast_json(True)["episode"]}}

    def api_refreshPodcasts(self, one, params):
        return {}

    def api_createPodcastChannel(self, one, params):
        return {}

    def api_downloadPodcastEpisode(self, one, params):
        return {}

    def api_deletePodcastEpisode(self, one, params):
        return {}

    def api_deletePodcastChannel(self, one, params):
        return {}

    # Shares
    def api_getShares(self, one, params):
        return {"shares": {"share": list(STATE["shares"].values())}}

    def api_createShare(self, one, params):
        sid = uuid.uuid4().hex[:8]
        entries = []
        for i in params.get("id", []):
            if i in ALBUMS:
                entries += album_json(i, True)["song"]
            elif i in STATE["playlists"]:
                entries += playlist_json(i, True)["entry"]
            else:
                entries.append(song(i))
        share = {"id": sid, "url": f"http://127.0.0.1:{self.server.server_port}/share/{sid}", "description": one("description"),
                 "username": USER, "created": "2026-11-02T10:00:00Z", "visitCount": 0, "entry": entries}
        STATE["shares"][sid] = {k: v for k, v in share.items() if v is not None}
        return {"shares": {"share": [STATE["shares"][sid]]}}

    def api_deleteShare(self, one, params):
        del STATE["shares"][one("id")]
        return {}

    # Lyrics
    def api_getLyricsBySongId(self, one, params):
        return {"lyricsList": {"structuredLyrics": [{"lang": "eng", "synced": True, "offset": 0, "line": [
            {"start": i * 4000, "value": f"Line {i + 1} of a tone"} for i in range(5)]}]}}

    def api_getLyrics(self, one, params):
        return {"lyrics": {"artist": one("artist"), "title": one("title"), "value": "Plain lyrics"}}

    # Media
    def api_getCoverArt(self, one, params):
        digest = hashlib.md5(one("id", "x").encode()).digest()
        return png(digest[:3]), "image/png"

    def api_stream(self, one, params):
        return self.audio(one("id"), one("format"))

    def api_download(self, one, params):
        return self.audio(one("id"), None)

    def audio(self, track_id, fmt):
        if track_id.startswith("pod"):
            path = os.path.join(self.media, "pod1.mp3")
            return open(path, "rb").read(), "audio/mpeg"
        t = next(t for t in TRACKS if t[0] == track_id)
        suffix = "mp3" if fmt == "mp3" else t[6]
        path = os.path.join(self.media, f"{track_id}.{suffix}")
        return open(path, "rb").read(), "audio/flac" if suffix == "flac" else "audio/mpeg"


def make_media(directory):
    os.makedirs(directory, exist_ok=True)
    jobs = [(f"{t[0]}.{t[6]}", t[4], t[5]) for t in TRACKS] + [(f"{t[0]}.mp3", t[4], t[5]) for t in TRACKS if t[6] != "mp3"]
    jobs.append(("pod1.mp3", 300, 600))
    for name, frequency, seconds in jobs:
        path = os.path.join(directory, name)
        if os.path.exists(path):
            continue
        codec = ["-c:a", "flac"] if name.endswith("flac") else ["-c:a", "libmp3lame", "-b:a", "48k", "-ac", "1"]
        subprocess.run(["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", f"sine=frequency={frequency}:duration={seconds}:sample_rate=44100",
                        "-af", "volume=0.05", *codec, path], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=4533)
    parser.add_argument("--media", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".mock-media"))
    args = parser.parse_args()
    make_media(args.media)
    Handler.media = args.media
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(json.dumps({"listening": f"http://127.0.0.1:{args.port}"}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
