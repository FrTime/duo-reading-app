import Foundation
import ZIPFoundation

/// Reads EPUB 2 and EPUB 3 metadata: the OPF package document, the cover
/// image, and for AO3 downloads the tags on the work's preface page.
public struct EPUBMetadataReader: MetadataReader {
    /// Cover images bigger than this are skipped rather than loaded into memory.
    static let maxCoverBytes: Int64 = 20 * 1024 * 1024
    /// Limit for XML and XHTML reads (container, OPF, preface), so a crafted
    /// archive can't inflate gigabytes into memory.
    static let maxDocumentBytes: Int64 = 5 * 1024 * 1024

    public init() {}

    public func readMetadata(from url: URL) throws -> BookMetadata {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw MetadataError.malformed("Not a ZIP archive")
        }

        if archive["META-INF/encryption.xml"] != nil, try isFontObfuscationOnly(archive) == false {
            throw MetadataError.drmProtected
        }

        guard
            let containerData = try Self.data(at: "META-INF/container.xml", in: archive),
            let opfPath = ContainerParser.rootfilePath(in: containerData),
            let opfData = try Self.data(at: opfPath, in: archive)
        else {
            throw MetadataError.malformed("Missing package document")
        }

        let package = OPFParser.parse(opfData)
        var metadata = package.metadata
        let base = (opfPath as NSString).deletingLastPathComponent

        if let coverHref = package.coverHref {
            let path = Self.resolve(coverHref, relativeTo: base)
            if let entry = archive[path], Int64(entry.uncompressedSize) <= Self.maxCoverBytes {
                metadata.coverImageData = try Self.data(at: path, in: archive, limit: Self.maxCoverBytes)
            }
        }

        if Self.isAO3(metadata) {
            var ao3 = AO3Metadata()
            ao3.workURL = metadata.identifiers
                .compactMap { URL(string: $0) }
                .first { $0.host()?.contains("archiveofourown.org") == true }
            // AO3 puts the tag block on the first page of the spine (the preface).
            var series: AO3PrefaceParser.Series?
            for href in package.spineHrefs.prefix(2) {
                let path = Self.resolve(href, relativeTo: base)
                if let page = try Self.data(at: path, in: archive) {
                    series = AO3PrefaceParser.parse(page, into: &ao3) ?? series
                }
                if !ao3.fandoms.isEmpty { break }
            }
            metadata.ao3 = ao3.isEmpty ? nil : ao3
            if metadata.series == nil, let series {
                metadata.series = series.name
                metadata.seriesIndex = series.index
            }
        }

        return metadata
    }

    // MARK: - Helpers

    /// Reads one entry, refusing entries larger than `limit` both by their
    /// declared size and by what actually inflates (the header can lie).
    static func data(at path: String, in archive: Archive, limit: Int64 = maxDocumentBytes) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        guard Int64(entry.uncompressedSize) <= limit else {
            throw MetadataError.malformed("Entry too large: \(path)")
        }
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: false) { chunk in
            guard Int64(data.count + chunk.count) <= limit else {
                throw MetadataError.malformed("Entry too large: \(path)")
            }
            data.append(chunk)
        }
        return data
    }

    /// Resolves an href from the OPF against the OPF's folder, handling `../`
    /// and percent-encoding.
    static func resolve(_ href: String, relativeTo base: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let withoutFragment = decoded.split(separator: "#", maxSplits: 1).first.map(String.init) ?? decoded
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for component in withoutFragment.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(component))
            }
        }
        return parts.joined(separator: "/")
    }

    static func isAO3(_ metadata: BookMetadata) -> Bool {
        metadata.publisher?.localizedCaseInsensitiveContains("Archive of Our Own") == true
            || metadata.identifiers.contains { $0.contains("archiveofourown.org") }
    }

    /// `encryption.xml` also shows up in DRM-free books that only obfuscate
    /// embedded fonts (IDPF or Adobe font mangling). Anything else is DRM.
    private func isFontObfuscationOnly(_ archive: Archive) throws -> Bool {
        guard let data = try Self.data(at: "META-INF/encryption.xml", in: archive),
              let xml = String(data: data, encoding: .utf8) else { return false }
        let algorithms = xml.matches(of: /Algorithm="([^"]+)"/).map { String($0.1) }
        let fontAlgorithms: Set<String> = [
            "http://www.idpf.org/2008/embedding",
            "http://ns.adobe.com/pdf/enc#RC",
        ]
        return !algorithms.isEmpty && algorithms.allSatisfy { fontAlgorithms.contains($0) }
    }
}

// MARK: - container.xml

enum ContainerParser {
    static func rootfilePath(in data: Data) -> String? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.path
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var path: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            if path == nil, localName(elementName) == "rootfile", let fullPath = attributes["full-path"] {
                path = fullPath
            }
        }
    }
}

// MARK: - OPF

struct OPFPackage {
    var metadata = BookMetadata()
    var coverHref: String?
    var spineHrefs: [String] = []
}

enum OPFParser {
    static func parse(_ data: Data) -> OPFPackage {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result()
    }

    private struct ManifestItem {
        var href: String
        var mediaType: String
        var properties: [String]
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var metadata = BookMetadata()
        var manifest: [String: ManifestItem] = [:]
        var spine: [String] = []
        var coverID: String?
        var guideCoverHref: String?

        private var text = ""
        private var inMetadata = false
        /// EPUB 3 refinements: id of a collection → its group position.
        private var collectionIDs: Set<String> = []
        private var refines: [(target: String, property: String, value: String)] = []
        private var currentID: String?
        private var currentProperty: String?
        private var currentRefines: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            text = ""
            let name = localName(elementName)
            switch name {
            case "metadata": inMetadata = true
            case "meta" where inMetadata:
                currentID = attributes["id"]
                currentProperty = attributes["property"]
                currentRefines = attributes["refines"]
                // EPUB 2 style: <meta name="…" content="…"/>
                if let metaName = attributes["name"], let content = attributes["content"] {
                    switch metaName {
                    case "cover": coverID = content
                    case "calibre:series": metadata.series = content.nilIfBlank
                    case "calibre:series_index": metadata.seriesIndex = Double(content)
                    default: break
                    }
                }
            case "item":
                if let id = attributes["id"], let href = attributes["href"] {
                    manifest[id] = ManifestItem(
                        href: href,
                        mediaType: attributes["media-type"] ?? "",
                        properties: (attributes["properties"] ?? "").split(separator: " ").map(String.init)
                    )
                }
            case "itemref":
                if let idref = attributes["idref"] { spine.append(idref) }
            case "reference":
                if attributes["type"] == "cover", guideCoverHref == nil { guideCoverHref = attributes["href"] }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            guard inMetadata else { return }
            switch localName(elementName) {
            case "metadata": inMetadata = false
            case "title": if metadata.title == nil { metadata.title = value.nilIfBlank }
            case "creator": if let v = value.nilIfBlank { metadata.authors.append(v) }
            case "language": if metadata.language == nil { metadata.language = value.nilIfBlank }
            case "publisher": if metadata.publisher == nil { metadata.publisher = value.nilIfBlank }
            case "description": if metadata.summary == nil { metadata.summary = HTMLText.plain(value).nilIfBlank }
            case "subject": if let v = value.nilIfBlank { metadata.subjects.append(v) }
            case "identifier": if let v = value.nilIfBlank { metadata.identifiers.append(v) }
            case "source": if let v = value.nilIfBlank { metadata.identifiers.append(v) }
            case "meta":
                if let property = currentProperty, !value.isEmpty {
                    if property == "belongs-to-collection", let id = currentID {
                        collectionIDs.insert(id)
                        if metadata.series == nil { metadata.series = value }
                    } else if let target = currentRefines {
                        refines.append((String(target.drop { $0 == "#" }), property, value))
                    }
                }
                currentID = nil; currentProperty = nil; currentRefines = nil
            default: break
            }
        }

        func result() -> OPFPackage {
            for refine in refines where refine.property == "group-position" && collectionIDs.contains(refine.target) {
                if metadata.seriesIndex == nil { metadata.seriesIndex = Double(refine.value) }
            }
            metadata.subjects = metadata.subjects.uniqued()
            metadata.authors = metadata.authors.uniqued()

            var package = OPFPackage(metadata: metadata)
            package.spineHrefs = spine.compactMap { manifest[$0]?.href }

            // EPUB 3 cover-image property, then the EPUB 2 <meta name="cover">,
            // then any image item whose id or href says "cover".
            let images = manifest.filter { $0.value.mediaType.hasPrefix("image/") }
            if let item = manifest.values.first(where: { $0.properties.contains("cover-image") }) {
                package.coverHref = item.href
            } else if let id = coverID, let item = manifest[id] ?? manifest.values.first(where: { $0.href == id }),
                      item.mediaType.hasPrefix("image/") {
                package.coverHref = item.href
            } else if let item = images.sorted(by: { $0.key < $1.key }).first(where: {
                $0.key.localizedCaseInsensitiveContains("cover") || $0.value.href.localizedCaseInsensitiveContains("cover")
            }) {
                package.coverHref = item.value.href
            }
            return package
        }
    }
}

// MARK: - AO3 preface

/// Parses the `<dl class="tags">` block on an AO3 preface page:
/// `<dt>Fandom:</dt><dd><a>Fandom A</a>, <a>Fandom B</a></dd>` and so on.
enum AO3PrefaceParser {
    struct Series: Equatable {
        var name: String
        var index: Double?
    }

    /// Fills `ao3` from the page and returns the series the work belongs to, if any.
    @discardableResult
    static func parse(_ data: Data, into ao3: inout AO3Metadata) -> Series? {
        var series: Series?
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        let pairs = html.matches(of: #/<dt[^>]*>(.*?)</dt>\s*<dd[^>]*>(.*?)</dd>/#.dotMatchesNewlines())
        for match in pairs {
            let label = HTMLText.plain(String(match.1))
                .trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespacesAndNewlines))
                .lowercased()
            let rawValue = String(match.2)
            let links = rawValue.matches(of: #/<a[^>]*>(.*?)</a>/#.dotMatchesNewlines())
                .map { HTMLText.plain(String($0.1)) }
                .filter { !$0.isEmpty }
            let plain = HTMLText.plain(rawValue)
            let list = links.isEmpty
                ? plain.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : links

            switch label {
            case "rating": ao3.rating = list.first ?? plain.nilIfBlank
            case "archive warning", "archive warnings": ao3.warnings = list
            case "category", "categories": ao3.categories = list
            case "fandom", "fandoms": ao3.fandoms = list
            case "relationship", "relationships": ao3.relationships = list
            case "character", "characters": ao3.characters = list
            case "additional tags", "freeform": ao3.additionalTags = list
            case "series":
                // "Part 2 of <a>Series Name</a>"
                if let name = links.first {
                    let index = plain.firstMatch(of: /Part (\d+)/).flatMap { Double($0.1) }
                    series = Series(name: name, index: index)
                }
            case "stats":
                if let words = plain.firstMatch(of: /Words:\s*([\d,]+)/) {
                    ao3.wordCount = Int(words.1.replacingOccurrences(of: ",", with: ""))
                }
                if let chapters = plain.firstMatch(of: #/Chapters:\s*([\d?]+/[\d?]+)/#) {
                    ao3.chapters = String(chapters.1)
                }
            default: break
            }
        }
        return series
    }
}

// MARK: - Small helpers

enum HTMLText {
    /// Strips tags and decodes the handful of entities that turn up in metadata.
    static func plain(_ html: String) -> String {
        var s = html.replacing(#/<br\s*/?>/#.ignoresCase(), with: "\n")
        s = s.replacing(#/</p>/#.ignoresCase(), with: "\n")
        s = s.replacing(/<[^>]+>/, with: "")
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, char) in entities { s = s.replacingOccurrences(of: entity, with: char) }
        s = s.replacing(/&#(\d+);/) { match in
            UInt32(match.1).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? ""
        }
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func localName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
