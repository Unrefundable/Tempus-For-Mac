#!/usr/bin/env swift
// Imports upstream Tempus's drawables, theme colors, fonts and launcher icon into the macOS asset catalogs.
//
//   swift scripts/import-tempus-assets.swift reference/tempus
//
// Android vector drawables become SVGs (asset catalogs keep them as vectors), Material theme
// colors become color sets with a dark variant, and the adaptive launcher icon becomes the
// macOS AppIcon. Rerun it after updating the reference submodule; it overwrites what it wrote.
//
// Derived from Tempus (GPL-3.0); the drawings are upstream's.

import AppKit
import Foundation

// MARK: - XML tree

final class Node {
    let name: String
    let attributes: [String: String]
    var children: [Node] = []
    var text: String?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    subscript(key: String) -> String? {
        attributes["android:\(key)"]
    }
}

final class TreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [Node] = []
    private(set) var root: Node?

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes: [String: String]
    ) {
        let node = Node(name: elementName, attributes: attributes)
        stack.last?.children.append(node)
        stack.append(node)
        if root == nil {
            root = node
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let node = stack.last else { return }
        node.text = (node.text ?? "") + trimmed
    }

    func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        stack.removeLast()
    }
}

func parseXML(_ url: URL) throws -> Node {
    let parser = try XMLParser(data: Data(contentsOf: url))
    let builder = TreeBuilder()
    parser.delegate = builder
    guard parser.parse(), let root = builder.root else {
        throw ImportError.unreadable(url.lastPathComponent, parser.parserError?.localizedDescription ?? "")
    }
    return root
}

enum ImportError: Error, CustomStringConvertible {
    case unreadable(String, String)
    case unknownColor(String, String)

    var description: String {
        switch self {
        case let .unreadable(file, reason): "Can't parse \(file): \(reason)"
        case let .unknownColor(file, color): "\(file): unknown color \(color)"
        }
    }
}

// MARK: - Colors

enum Appearance { case light, dark }

struct RGBA {
    let hex: String
    let alpha: Double

    /// Android writes `#RGB`, `#ARGB`, `#RRGGBB` or `#AARRGGBB`.
    init?(android value: String) {
        var digits = value.dropFirst().uppercased()
        guard value.hasPrefix("#"), digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 || digits.count == 4 {
            digits = String(digits.flatMap { [$0, $0] })
        }
        switch digits.count {
        case 6:
            hex = digits
            alpha = 1
        case 8:
            hex = String(digits.dropFirst(2))
            alpha = Double(Int(digits.prefix(2), radix: 16) ?? 255) / 255
        default:
            return nil
        }
    }

    var components: (red: Double, green: Double, blue: Double) {
        let value = Int(hex, radix: 16) ?? 0
        return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

struct Palette {
    private let light: [String: String]
    private let dark: [String: String]
    /// Color state lists in `res/color`, by name, as their default (unconditioned) item.
    private let stateLists: [String: String]

    /// The Material roles the drawables reference through `?attr/`, as the app theme assigns them.
    private static let themeAttributes = [
        "colorPrimary": "primary",
        "colorPrimaryContainer": "primaryContainer",
        "colorSurface": "surface",
        "colorSurfaceVariant": "surfaceVariant",
        "colorOnSurfaceVariant": "onSurfaceVariant",
        "colorControlNormal": "onSurfaceVariant",
    ]

    init(resources: URL) throws {
        func colors(_ folder: String) throws -> [String: String] {
            let file = resources.appending(path: "\(folder)/colors.xml")
            return try parseXML(file).children.reduce(into: [:]) { result, node in
                if let name = node.attributes["name"], let value = node.text {
                    result[name] = value
                }
            }
        }
        light = try colors("values")
        dark = try light.merging(colors("values-night")) { _, night in night }

        let folder = resources.appending(path: "color")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        stateLists = try files.filter { $0.pathExtension == "xml" }.reduce(into: [:]) { result, file in
            let items = try parseXML(file).children.filter { $0.name == "item" }
            let fallback = items.last { $0.attributes.keys.allSatisfy { !$0.contains("state_") } }
            if let color = fallback?["color"] {
                result[file.deletingPathExtension().lastPathComponent] = color
            }
        }
    }

    func materialRole(_ role: String, _ appearance: Appearance) -> String? {
        let table = appearance == .light ? light : dark
        return table["md_theme_\(appearance == .light ? "light" : "dark")_\(role)"]
    }

    func named(_ name: String, _ appearance: Appearance) -> String? {
        (appearance == .light ? light : dark)[name]
    }

    /// Resolves a literal, `@color/`, `@android:color/` or `?attr/` value to a color.
    func resolve(_ value: String, _ appearance: Appearance, file: String) throws -> RGBA {
        if value.hasPrefix("@color/"), let item = stateLists[String(value.dropFirst("@color/".count))] {
            return try resolve(item, appearance, file: file)
        }
        let literal: String? = if value.hasPrefix("@color/") {
            named(String(value.dropFirst("@color/".count)), appearance)
        } else if value.hasPrefix("?attr/") {
            Self.themeAttributes[String(value.dropFirst("?attr/".count))].flatMap { materialRole($0, appearance) }
        } else if value == "@android:color/white" {
            "#FFFFFF"
        } else if value == "@android:color/black" {
            "#000000"
        } else {
            value
        }
        guard let literal, let color = RGBA(android: literal) else { throw ImportError.unknownColor(file, value) }
        return color
    }
}

// MARK: - Vector drawable to SVG

struct SVGWriter {
    let palette: Palette
    let appearance: Appearance
    let file: String
    private var definitions: [String] = []
    private var nextID = 0

    init(palette: Palette, appearance: Appearance, file: String) {
        self.palette = palette
        self.appearance = appearance
        self.file = file
    }

    private func color(_ value: String) throws -> RGBA {
        try palette.resolve(value, appearance, file: file)
    }

    mutating func svg(for vector: Node) throws -> String {
        let width = vector["width"].map(stripUnit) ?? "24"
        let height = vector["height"].map(stripUnit) ?? "24"
        let viewBox = "0 0 \(vector["viewportWidth"] ?? width) \(vector["viewportHeight"] ?? height)"
        let body = try contents(of: vector.children)
        let defs = definitions.isEmpty ? "" : "<defs>\(definitions.joined())</defs>"
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="\(viewBox)">\
        \(defs)\(body)</svg>

        """
    }

    /// A `clip-path` clips the siblings that follow it inside the same group.
    private mutating func contents(of nodes: [Node]) throws -> String {
        var output = ""
        for (index, node) in nodes.enumerated() {
            switch node.name {
            case "path":
                output += try path(node)
            case "group":
                output += try group(node)
            case "clip-path":
                let id = makeID("clip")
                definitions.append("<clipPath id=\"\(id)\"><path d=\"\(node["pathData"] ?? "")\"/></clipPath>")
                let rest = try contents(of: Array(nodes[(index + 1)...]))
                return output + "<g clip-path=\"url(#\(id))\">\(rest)</g>"
            default:
                continue
            }
        }
        return output
    }

    /// Android scales and rotates about the pivot, then translates.
    private mutating func group(_ node: Node) throws -> String {
        let pivotX = Double(node["pivotX"] ?? "0") ?? 0
        let pivotY = Double(node["pivotY"] ?? "0") ?? 0
        let translateX = Double(node["translateX"] ?? "0") ?? 0
        let translateY = Double(node["translateY"] ?? "0") ?? 0
        let transform = [
            "translate(\(format(translateX + pivotX)) \(format(translateY + pivotY)))",
            "rotate(\(node["rotation"] ?? "0"))",
            "scale(\(node["scaleX"] ?? "1") \(node["scaleY"] ?? "1"))",
            "translate(\(format(-pivotX)) \(format(-pivotY)))",
        ].joined(separator: " ")
        return try "<g transform=\"\(transform)\">\(contents(of: node.children))</g>"
    }

    private mutating func path(_ node: Node) throws -> String {
        var attributes = ["d=\"\(node["pathData"] ?? "")\""]
        attributes += try paint(node, fill: true)
        let stroke = try paint(node, fill: false)
        attributes += stroke
        if !stroke.isEmpty {
            attributes.append("stroke-width=\"\(node["strokeWidth"] ?? "0")\"")
        }
        if let cap = node["strokeLineCap"] {
            attributes.append("stroke-linecap=\"\(cap)\"")
        }
        if let join = node["strokeLineJoin"] {
            attributes.append("stroke-linejoin=\"\(join)\"")
        }
        if let limit = node["strokeMiterLimit"] {
            attributes.append("stroke-miterlimit=\"\(limit)\"")
        }
        if node["fillType"] == "evenOdd" {
            attributes.append("fill-rule=\"evenodd\"")
        }
        return "<path \(attributes.joined(separator: " "))/>"
    }

    /// Android leaves fill and stroke empty unless they're set.
    private mutating func paint(_ node: Node, fill: Bool) throws -> [String] {
        let role = fill ? "fill" : "stroke"
        let alpha = Double(node[fill ? "fillAlpha" : "strokeAlpha"] ?? "1") ?? 1
        if let gradient = gradient(node, fill ? "android:fillColor" : "android:strokeColor") {
            return try ["\(role)=\"url(#\(define(gradient)))\"", "\(role)-opacity=\"\(format(alpha))\""]
        }
        guard let value = node[fill ? "fillColor" : "strokeColor"] else {
            return fill ? ["fill=\"none\""] : []
        }
        let resolved = try color(value)
        return ["\(role)=\"#\(resolved.hex)\"", "\(role)-opacity=\"\(format(resolved.alpha * alpha))\""]
    }

    private func gradient(_ node: Node, _ attribute: String) -> Node? {
        node.children.first { $0.name == "aapt:attr" && $0.attributes["name"] == attribute }?
            .children.first { $0.name == "gradient" }
    }

    private mutating func define(_ gradient: Node) throws -> String {
        let id = makeID("gradient")
        var stops = try gradient.children.filter { $0.name == "item" }.map { item in
            try stop(offset: item["offset"] ?? "0", color: item["color"] ?? "#000")
        }
        if stops.isEmpty {
            stops = try [("0", gradient["startColor"]), ("0.5", gradient["centerColor"]), ("1", gradient["endColor"])]
                .compactMap { offset, color in try color.map { try stop(offset: offset, color: $0) } }
        }
        let radial = gradient["type"] == "radial"
        let tag = radial ? "radialGradient" : "linearGradient"
        let geometry = radial
            ? "cx=\"\(gradient["centerX"] ?? "0")\" cy=\"\(gradient["centerY"] ?? "0")\" r=\"\(gradient["gradientRadius"] ?? "0")\""
            : "x1=\"\(gradient["startX"] ?? "0")\" y1=\"\(gradient["startY"] ?? "0")\" "
            + "x2=\"\(gradient["endX"] ?? "0")\" y2=\"\(gradient["endY"] ?? "0")\""
        definitions
            .append("<\(tag) id=\"\(id)\" \(geometry) gradientUnits=\"userSpaceOnUse\">\(stops.joined())</\(tag)>")
        return id
    }

    private func stop(offset: String, color: String) throws -> String {
        let rgba = try self.color(color)
        return "<stop offset=\"\(offset)\" stop-color=\"#\(rgba.hex)\" stop-opacity=\"\(format(rgba.alpha))\"/>"
    }

    private mutating func makeID(_ prefix: String) -> String {
        nextID += 1
        return "\(prefix)\(nextID)"
    }
}

func stripUnit(_ value: String) -> String {
    String(value.prefix { $0.isNumber || $0 == "." })
}

func format(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.6g", value)
}

// MARK: - Asset catalog

struct Catalog {
    let root: URL
    private let manager = FileManager.default
    let info: [String: Any] = ["author": "xcode", "version": 1]

    func reset(folder: String) throws {
        let url = root.appending(path: folder)
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        try write(json: ["info": info], to: url.appending(path: "Contents.json"))
    }

    func write(json: [String: Any], to url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    /// Writes an image set. A dark SVG, when it differs, becomes the dark-appearance variant.
    func imageSet(folder: String, name: String, light: String, dark: String?, template: Bool) throws {
        let directory = root.appending(path: "\(folder)/\(name).imageset")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try light.write(to: directory.appending(path: "\(name).svg"), atomically: true, encoding: .utf8)
        var images: [[String: Any]] = [["filename": "\(name).svg", "idiom": "universal"]]
        if let dark, dark != light {
            try dark.write(to: directory.appending(path: "\(name)-dark.svg"), atomically: true, encoding: .utf8)
            images.append([
                "appearances": [["appearance": "luminosity", "value": "dark"]],
                "filename": "\(name)-dark.svg",
                "idiom": "universal",
            ])
        }
        try write(json: [
            "images": images,
            "info": info,
            "properties": [
                "preserves-vector-representation": true,
                "template-rendering-intent": template ? "template" : "original",
            ],
        ], to: directory.appending(path: "Contents.json"))
    }

    func colorSet(folder: String, name: String, light: RGBA, dark: RGBA) throws {
        func entry(_ color: RGBA) -> [String: Any] {
            let (red, green, blue) = color.components
            return ["color-space": "srgb", "components": [
                "red": String(format: "%.3f", red), "green": String(format: "%.3f", green),
                "blue": String(format: "%.3f", blue), "alpha": String(format: "%.3f", color.alpha),
            ]]
        }
        let dark: [String: Any] = [
            "appearances": [["appearance": "luminosity", "value": "dark"]],
            "color": entry(dark),
            "idiom": "universal",
        ]
        try write(
            json: ["colors": [["color": entry(light), "idiom": "universal"], dark], "info": info],
            to: root.appending(path: "\(folder)/\(name).colorset/Contents.json")
        )
    }
}

// MARK: - Drawables

/// Which upstream drawables come across, and how they render.
enum Kind: CaseIterable {
    /// Monochrome toolbar and control icons, tinted by SwiftUI's foreground style.
    case icon
    /// Artwork placeholders, drawn in theme colors for each appearance.
    case placeholder
    /// Full-color empty-state illustrations and the logo.
    case illustration

    /// The `ic_` drawables drawn in full color: the logo on the toolbar and the login greeter.
    static let coloredIcons: Set = ["ic_splash_logo", "ic_toolbar_tempo"]

    /// Skips the launcher layers (they become the app icon), the rotated copies upstream uses on
    /// its landscape navigation rail, and the splash screen.
    init?(drawable name: String) {
        if name.hasPrefix("ic_launcher_") || name.hasSuffix("_land") {
            return nil
        }
        if name.hasPrefix("ic_placeholder_") {
            self = .placeholder
        } else if (name.hasPrefix("ui_") && name != "ui_splash_screen") || name == "logo" || Self.coloredIcons
            .contains(name)
        {
            self = .illustration
        } else if name.hasPrefix("ic_") {
            self = .icon
        } else {
            return nil
        }
    }

    var folder: String {
        switch self {
        case .icon: "Icons"
        case .placeholder: "Placeholders"
        case .illustration: "Illustrations"
        }
    }
}

struct ConvertedDrawable {
    let kind: Kind
    let name: String
    let light: String
    let dark: String?
}

/// Converts every drawable before the catalog is touched, so a drawable that fails leaves the
/// previous import in place.
func importDrawables(resources: URL, palette: Palette, catalog: Catalog) throws -> [Kind: Int] {
    let folder = resources.appending(path: "drawable")
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    let converted = try files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
        try convert(file)
    }

    for kind in Kind.allCases {
        try catalog.reset(folder: kind.folder)
    }
    for drawable in converted {
        try catalog.imageSet(
            folder: drawable.kind.folder,
            name: drawable.name,
            light: drawable.light,
            dark: drawable.dark,
            template: drawable.kind == .icon
        )
    }
    return converted.reduce(into: [:]) { counts, drawable in counts[drawable.kind, default: 0] += 1 }

    func convert(_ file: URL) throws -> ConvertedDrawable? {
        let name = file.deletingPathExtension().lastPathComponent
        guard file.pathExtension == "xml", let kind = Kind(drawable: name) else { return nil }
        let root = try parseXML(file)
        guard root.name == "vector" else { return nil }
        var light = SVGWriter(palette: palette, appearance: .light, file: file.lastPathComponent)
        var dark = SVGWriter(palette: palette, appearance: .dark, file: file.lastPathComponent)
        return try ConvertedDrawable(
            kind: kind,
            name: name,
            light: light.svg(for: root),
            dark: kind == .icon ? nil : dark.svg(for: root)
        )
    }
}

// MARK: - Colors

/// The colors upstream fixes for itself, exported as color sets. Its Material roles (primary,
/// surface and the rest) aren't: by default upstream takes them from the wallpaper
/// (`Preferences.isDynamicColorAccent()`), and the `md_theme_*` values are only Material 3's
/// baseline fallback. The Mac takes them from the system accent and window colors instead.
let colorTokens: [(asset: String, source: (Palette, Appearance) -> String?)] = [
    ("titleText", { $0.named("titleTextColor", $1) }),
    ("subtitleText", { $0.named("subtitleTextColor", $1) }),
    ("divider", { $0.named("dividerColor", $1) }),
    ("deleteIcon", { $0.named("deleteIconColor", $1) }),
    ("lyricsText", { $0.named("lyricsTextColor", $1) }),
    ("lyricsShadowText", { $0.named("shadowsLyricsTextColor", $1) }),
]

func importColors(palette: Palette, catalog: Catalog) throws {
    try catalog.reset(folder: "Colors")
    for token in colorTokens {
        guard let light = token.source(palette, .light).flatMap(RGBA.init(android:)),
              let dark = token.source(palette, .dark).flatMap(RGBA.init(android:))
        else { throw ImportError.unknownColor("colors.xml", token.asset) }
        try catalog.colorSet(folder: "Colors", name: token.asset, light: light, dark: dark)
    }
}

// MARK: - App icon

/// Draws the adaptive icon's background and foreground on the macOS icon grid: an 824-point
/// rounded square centered on a 1024-point canvas.
func importAppIcon(resources: URL, palette: Palette, appIconSet: URL) throws {
    let background = try parseXML(resources.appending(path: "drawable/ic_launcher_background.xml"))
    let foreground = try parseXML(resources.appending(path: "drawable/ic_launcher_foreground.xml"))
    let layers = Node(name: "vector", attributes: foreground.attributes)
    layers.children = background.children + foreground.children
    var writer = SVGWriter(palette: palette, appearance: .light, file: "ic_launcher")
    guard let artwork = try NSImage(data: Data(writer.svg(for: layers).utf8)) else {
        throw ImportError.unreadable("ic_launcher", "AppKit can't render the SVG")
    }

    var images: [[String: Any]] = []
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
            try renderIcon(artwork, pixels: size * scale).write(to: appIconSet.appending(path: filename))
            images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
        }
    }
    let catalog = Catalog(root: appIconSet)
    try catalog.write(json: ["images": images, "info": catalog.info], to: appIconSet.appending(path: "Contents.json"))
}

/// The launcher layers are 108 dp with the logo in the middle 72 dp, so the tile crops to that
/// safe zone's surroundings the way Android's adaptive mask does.
func renderIcon(_ artwork: NSImage, pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw ImportError.unreadable("ic_launcher", "can't allocate a bitmap") }
    let canvas = CGFloat(pixels)
    let inset = canvas * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let bleed = tile.width * 18 / 72
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225).addClip()
    artwork.draw(in: tile.insetBy(dx: -bleed, dy: -bleed))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw ImportError.unreadable("ic_launcher", "can't encode a PNG")
    }
    return png
}

// MARK: - Fonts

/// The Inter weights upstream's text styles use (300 to 700).
let fontFiles = [
    "inter_light.ttf": "Inter-Light.ttf",
    "inter_regular.ttf": "Inter-Regular.ttf",
    "inter_medium.ttf": "Inter-Medium.ttf",
    "inter_semi_bold.ttf": "Inter-SemiBold.ttf",
    "inter_bold.ttf": "Inter-Bold.ttf",
]

func importFonts(resources: URL, destination: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    for (source, target) in fontFiles {
        let url = destination.appending(path: target)
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        try manager.copyItem(at: resources.appending(path: "font/\(source)"), to: url)
    }
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError
        .write(Data("usage: swift scripts/import-tempus-assets.swift <path to reference/tempus>\n".utf8))
    exit(64)
}

let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard FileManager.default.fileExists(atPath: repository.appending(path: "TempusMac/TempusMac.xcodeproj").path) else {
    FileHandle.standardError.write(Data("Run this from the repository root.\n".utf8))
    exit(64)
}

let resources = URL(fileURLWithPath: arguments[1]).appending(path: "app/src/main/res")
let designSystem = repository.appending(path: "TempusMac/Packages/TempusKit/Sources/DesignSystem/Resources")

do {
    let palette = try Palette(resources: resources)
    let catalog = Catalog(root: designSystem.appending(path: "Tempus.xcassets"))
    try catalog.write(json: ["info": catalog.info], to: catalog.root.appending(path: "Contents.json"))
    let counts = try importDrawables(resources: resources, palette: palette, catalog: catalog)
    try importColors(palette: palette, catalog: catalog)
    try importFonts(resources: resources, destination: designSystem.appending(path: "Fonts"))
    let appCatalog = Catalog(root: repository.appending(path: "TempusMac/Tempus/Assets.xcassets"))
    try appCatalog.write(json: ["info": appCatalog.info], to: appCatalog.root.appending(path: "Contents.json"))
    try importAppIcon(
        resources: resources,
        palette: palette,
        appIconSet: appCatalog.root.appending(path: "AppIcon.appiconset")
    )
    print(
        "Imported \(counts[.icon] ?? 0) icons, \(counts[.placeholder] ?? 0) placeholders,",
        "\(counts[.illustration] ?? 0) illustrations, \(colorTokens.count) colors, \(fontFiles.count) fonts",
        "and the app icon."
    )
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
