#!/usr/bin/env swift
// Adds a release to appcast.xml, the feed Sparkle reads for updates. scripts/release.sh runs it;
// the feed is signed afterwards with Sparkle's sign_update.
//
//   swift scripts/add-appcast-item.swift appcast.xml \
//       --version 0.2.0-beta.1 --build 42 --url https://…/Tempus-0.2.0-beta.1-macOS.zip \
//       --length 11959464 --signature <EdDSA signature> --notes https://…/releases/tag/v0.2.0-beta.1
//
// A version with a pre-release suffix ("-beta.1") goes in the `beta` channel, which only users
// with beta updates on are offered. The newest item goes first.

import Foundation

enum AppcastError: Error, CustomStringConvertible {
    case usage(String)
    case unreadable(String)
    case notNewer(build: String, newest: Int)

    var description: String {
        switch self {
        case let .usage(message): "\(message)\nUsage: add-appcast-item.swift <appcast.xml> --version V --build N "
            + "--url URL --length BYTES --signature SIG [--notes URL] [--minimum-system 15.0]"
        case let .unreadable(reason): "Can't read the appcast: \(reason)"
        case let .notNewer(build, newest): "Build \(build) isn't newer than build \(newest), already in the appcast. "
            + "Sparkle only offers higher builds."
        }
    }
}

struct Release {
    let version: String
    let build: String
    let url: String
    let length: String
    let signature: String
    let notes: String?
    let minimumSystem: String

    var isPrerelease: Bool {
        (version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").contains("-")
    }

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            guard flag.hasPrefix("--"), index + 1 < arguments.endIndex else {
                throw AppcastError.usage("Unexpected argument \(flag).")
            }
            values[String(flag.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        func required(_ name: String) throws -> String {
            guard let value = values[name], !value.isEmpty else { throw AppcastError.usage("Missing --\(name).") }
            return value
        }
        version = try required("version")
        build = try required("build")
        url = try required("url")
        length = try required("length")
        signature = try required("signature")
        notes = values["notes"]
        minimumSystem = values["minimum-system"] ?? "15.0"
        guard Int(build) != nil, Int(length) != nil else {
            throw AppcastError.usage("--build and --length must be whole numbers.")
        }
        guard URL(string: url)?.scheme == "https" else { throw AppcastError.usage("--url must be https.") }
    }
}

let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"

func element(_ name: String, _ text: String) -> XMLElement {
    XMLElement(name: name, stringValue: text)
}

func attribute(_ name: String, _ value: String) -> XMLNode {
    let node = XMLNode(kind: .attribute)
    node.name = name
    node.stringValue = value
    return node
}

func item(for release: Release, date: Date) -> XMLElement {
    let item = XMLElement(name: "item")
    item.addChild(element("title", "Version \(release.version)"))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    item.addChild(element("pubDate", formatter.string(from: date)))
    item.addChild(element("sparkle:version", release.build))
    item.addChild(element("sparkle:shortVersionString", release.version))
    if release.isPrerelease {
        item.addChild(element("sparkle:channel", "beta"))
    }
    item.addChild(element("sparkle:minimumSystemVersion", release.minimumSystem))
    if let notes = release.notes {
        item.addChild(element("sparkle:fullReleaseNotesLink", notes))
    }
    let enclosure = XMLElement(name: "enclosure")
    enclosure.addAttribute(attribute("url", release.url))
    enclosure.addAttribute(attribute("length", release.length))
    enclosure.addAttribute(attribute("type", "application/octet-stream"))
    enclosure.addAttribute(attribute("sparkle:edSignature", release.signature))
    item.addChild(enclosure)
    return item
}

func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let path = arguments.first else { throw AppcastError.usage("Missing the appcast path.") }
    let release = try Release(arguments: Array(arguments.dropFirst()))
    let file = URL(fileURLWithPath: path)

    let document: XMLDocument
    do {
        document = try XMLDocument(contentsOf: file, options: [.nodePreserveWhitespace])
    } catch {
        throw AppcastError.unreadable(error.localizedDescription)
    }
    guard let channel = try document.nodes(forXPath: "/rss/channel").first as? XMLElement else {
        throw AppcastError.unreadable("no <rss><channel>.")
    }
    let newest = channel.elements(forName: "item").compactMap {
        $0.elements(forName: "sparkle:version").first?.stringValue.flatMap { Int($0) }
    }.max()
    if let newest, Int(release.build) ?? 0 <= newest {
        throw AppcastError.notNewer(build: release.build, newest: newest)
    }

    let newItem = item(for: release, date: Date())
    if let first = channel.elements(forName: "item").first {
        channel.insertChild(newItem, at: first.index)
    } else {
        channel.addChild(newItem)
    }
    try document.xmlData(options: [.nodePrettyPrint]).write(to: file)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
