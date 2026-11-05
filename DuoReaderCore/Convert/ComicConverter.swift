import Foundation
import ImageIO
import ReadiumZIPFoundation

/// Converts CBZ comics into fixed-layout EPUB: one page per image, in natural
/// file-name order ("page2" before "page10"). The reader then shows them like
/// any other book, including two-page spreads on the Duo's inner display, and
/// saved places work the same way.
///
/// `ComicInfo.xml` (the ComicRack format some CBZ files carry) fills in the
/// title, series and number, writers, summary, language and manga reading
/// direction. Without it, the title, series and volume come from the file
/// name (`FileNameTitle`). Pages are copied without recompressing.
public struct ComicConverter: FileConverter {
    /// A single page bigger than this is not a comic page.
    static let maxPageBytes: Int64 = 60 * 1024 * 1024
    static let maxPages = 5_000
    /// Far above any real comic; stops a crafted archive filling the disk.
    static let maxTotalBytes: Int64 = 2 * 1024 * 1024 * 1024

    public init() {}

    public func convert(_ source: URL, to destination: URL) async throws {
        let archive: Archive
        do {
            archive = try await Archive(url: source, accessMode: .read)
        } catch {
            throw ConversionError.unreadable
        }
        let entries = try await archive.entries()
        let pages = Self.pageEntries(entries)
        guard !pages.isEmpty else { throw ConversionError.unreadable }
        guard Self.withinLimits(pageSizes: pages.map { Int64($0.uncompressedSize) }) else {
            throw ConversionError.tooLarge
        }

        var info = ComicInfo()
        if let entry = entries.first(where: { $0.path.lowercased().hasSuffix("comicinfo.xml") }),
           let data = try? await EPUBMetadataReader.data(at: entry.path, in: archive) {
            info = ComicInfo.parse(data)
        }

        try? FileManager.default.removeItem(at: destination)
        let output = try await Archive(url: destination, accessMode: .create)
        try await Self.add("mimetype", Data("application/epub+zip".utf8), to: output, compress: false)
        try await Self.add("META-INF/container.xml", Data(EPUBWriter.containerXML.utf8), to: output)

        var manifest: [Page] = []
        for (index, entry) in pages.enumerated() {
            guard Int64(entry.uncompressedSize) <= Self.maxPageBytes else { throw ConversionError.tooLarge }
            guard let data = try await EPUBMetadataReader.data(at: entry.path, in: archive, limit: Self.maxPageBytes) else {
                throw ConversionError.unreadable
            }
            let ext = Self.imageExtension(entry.path)
            let page = Page(number: index + 1, imageName: String(format: "p%04d.%@", index + 1, ext), size: Self.pixelSize(of: data))
            // Images are already compressed; storing them is faster and no bigger.
            try await Self.add("OEBPS/images/\(page.imageName)", data, to: output, compress: false)
            try await Self.add("OEBPS/pages/\(page.pageName)", Data(Self.pageXHTML(page).utf8), to: output)
            manifest.append(page)
        }

        // Most CBZ files have no ComicInfo.xml, only a release name such as
        // "Claymore v15 (2009) (Digital) (Group).cbz". Read what it can tell us.
        let fromName = FileNameTitle(fileName: source.lastPathComponent)
        let title = info.displayTitle ?? fromName.title
        if info.series == nil, let series = fromName.series {
            info.series = series
            if info.number == nil { info.number = fromName.seriesIndex.map(FileNameTitleParser.number) }
        }
        try await Self.add("OEBPS/nav.xhtml", Data(Self.navigation(title: title, first: manifest[0]).utf8), to: output)
        try await Self.add("OEBPS/content.opf", Data(Self.packageDocument(title: title, info: info, pages: manifest).utf8), to: output)
    }

    // MARK: - Pages

    /// Page count, each page and the total under their caps.
    static func withinLimits(pageSizes: [Int64]) -> Bool {
        pageSizes.count <= maxPages
            && pageSizes.allSatisfy { $0 <= maxPageBytes }
            && pageSizes.reduce(0, +) <= maxTotalBytes
    }

    struct Page {
        let number: Int
        let imageName: String
        let size: CGSize
        var pageName: String { String(format: "p%04d.xhtml", number) }
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]

    /// Image entries in reading order, skipping macOS metadata and hidden files.
    static func pageEntries(_ entries: [Entry]) -> [Entry] {
        entries
            .filter { entry in
                guard entry.type == .file else { return false }
                let parts = entry.path.split(separator: "/")
                guard !parts.contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }) else { return false }
                return imageExtensions.contains((entry.path as NSString).pathExtension.lowercased())
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func imageExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "jpeg" ? "jpg" : ext
    }

    static func mediaType(_ ext: String) -> String {
        switch ext {
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "image/jpeg"
        }
    }

    /// Reads just the image header for its size; a 2:3 page if unknown.
    static func pixelSize(of data: Data) -> CGSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return CGSize(width: 1000, height: 1500)
        }
        return CGSize(width: width, height: height)
    }

    static func pageXHTML(_ page: Page) -> String {
        let width = Int(page.size.width), height = Int(page.size.height)
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><meta charset="UTF-8"/><meta name="viewport" content="width=\(width), height=\(height)"/><title>\(page.number)</title>
            <style>html, body { margin: 0; padding: 0; } img { display: block; width: \(width)px; height: \(height)px; }</style></head>
            <body><img src="../images/\(page.imageName)" alt="Page \(page.number)"/></body>
            </html>
            """
    }

    static func navigation(title: String, first: Page) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="UTF-8"/><title>\(XHTML.escape(title))</title></head>
        <body><nav epub:type="toc" id="toc"><ol><li><a href="pages/\(first.pageName)">\(XHTML.escape(title))</a></li></ol></nav></body>
        </html>
        """
    }

    static func packageDocument(title: String, info: ComicInfo, pages: [Page]) -> String {
        let e = XHTML.escape
        var metadata = """
                <dc:identifier id="book-id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
                <dc:title>\(e(title))</dc:title>
                <dc:language>\(e(info.language ?? "en"))</dc:language>
                <meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: .now).prefix(19))Z</meta>
                <meta property="rendition:layout">pre-paginated</meta>
                <meta property="rendition:spread">landscape</meta>
                <meta name="cover" content="image-1"/>

        """
        for writer in info.writers { metadata += "        <dc:creator>\(e(writer))</dc:creator>\n" }
        if let summary = info.summary { metadata += "        <dc:description>\(e(summary))</dc:description>\n" }
        if let series = info.series {
            metadata += "        <meta name=\"calibre:series\" content=\"\(e(series))\"/>\n"
            if let number = info.number { metadata += "        <meta name=\"calibre:series_index\" content=\"\(e(number))\"/>\n" }
        }
        var manifest = """
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>

        """
        var spine = ""
        for page in pages {
            let ext = (page.imageName as NSString).pathExtension
            let cover = page.number == 1 ? #" properties="cover-image""# : ""
            manifest += #"        <item id="image-\#(page.number)" href="images/\#(page.imageName)" media-type="\#(mediaType(ext))"\#(cover)/>"# + "\n"
            manifest += #"        <item id="page-\#(page.number)" href="pages/\#(page.pageName)" media-type="application/xhtml+xml"/>"# + "\n"
            spine += #"        <itemref idref="page-\#(page.number)"/>"# + "\n"
        }
        let direction = info.rightToLeft ? #" page-progression-direction="rtl""# : ""
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(metadata)  </metadata>
              <manifest>
            \(manifest)  </manifest>
              <spine\(direction)>
            \(spine)  </spine>
            </package>
            """
    }

    private static func add(_ path: String, _ data: Data, to archive: Archive, compress: Bool = true) async throws {
        try await archive.addEntry(
            with: path, type: .file, uncompressedSize: Int64(data.count),
            compressionMethod: compress ? .deflate : .none
        ) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
}

/// The fields of ComicRack's `ComicInfo.xml` that the library uses.
struct ComicInfo: Equatable {
    var title: String?
    var series: String?
    var number: String?
    var writers: [String] = []
    var summary: String?
    var language: String?
    var rightToLeft = false

    /// "Title", or "Series #3" when there's no title.
    var displayTitle: String? {
        if let title { return title }
        guard let series else { return nil }
        return number.map { "\(series) #\($0)" } ?? series
    }

    static func parse(_ data: Data) -> ComicInfo {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        parser.parse()
        let values = collector.values
        var info = ComicInfo()
        info.title = values["Title"]
        info.series = values["Series"]
        info.number = values["Number"]
        info.writers = (values["Writer"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        info.summary = values["Summary"]
        info.language = values["LanguageISO"]
        info.rightToLeft = values["Manga"] == "YesAndRightToLeft"
        return info
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, values[elementName] == nil { values[elementName] = value }
            text = ""
        }
    }
}
