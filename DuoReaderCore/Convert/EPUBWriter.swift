import Foundation
import ReadiumZIPFoundation

/// Writes an `EPUBDocument` as a valid EPUB 3 file.
public enum EPUBWriter {
    public static func write(_ document: EPUBDocument, to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try await Archive(url: url, accessMode: .create)
        for (path, data) in files(for: document) {
            // The mimetype entry must come first and be stored uncompressed.
            try await archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count),
                compressionMethod: path == "mimetype" ? .none : .deflate
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    /// The archive's entries in write order.
    static func files(for document: EPUBDocument) -> [(String, Data)] {
        let chapters = document.chapters.isEmpty ? [.init(title: nil, body: "<p></p>")] : document.chapters
        let names = chapters.indices.map { String(format: "text/chapter-%03d.xhtml", $0 + 1) }
        var files: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/content.opf", Data(packageDocument(document, chapterFiles: names).utf8)),
            ("OEBPS/nav.xhtml", Data(navigation(document, chapters: chapters, files: names).utf8)),
            ("OEBPS/style.css", Data(stylesheet.utf8)),
        ]
        if let cover = document.coverImage, let type = imageType(cover) {
            files.append(("OEBPS/cover.\(type.ext)", cover))
        }
        for (chapter, name) in zip(chapters, names) {
            files.append(("OEBPS/\(name)", Data(page(chapter, bookTitle: document.title, language: document.language).utf8)))
        }
        return files
    }

    static let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    static func packageDocument(_ document: EPUBDocument, chapterFiles: [String]) -> String {
        let e = XHTML.escape
        let modified = ISO8601DateFormatter().string(from: .now)
        var metadata = """
                <dc:identifier id="book-id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
                <dc:title>\(e(document.title))</dc:title>
                <dc:language>\(e(document.language))</dc:language>
                <meta property="dcterms:modified">\(modified.prefix(19))Z</meta>

        """
        for identifier in document.sourceIdentifiers {
            metadata += "        <dc:identifier>\(e(identifier))</dc:identifier>\n"
        }
        for author in document.authors {
            metadata += "        <dc:creator>\(e(author))</dc:creator>\n"
        }
        if let publisher = document.publisher {
            metadata += "        <dc:publisher>\(e(publisher))</dc:publisher>\n"
        }
        if let summary = document.summary {
            metadata += "        <dc:description>\(e(summary))</dc:description>\n"
        }
        let manifest = chapterFiles.enumerated().map { index, file in
            #"        <item id="c\#(index + 1)" href="\#(file)" media-type="application/xhtml+xml"/>"#
        }.joined(separator: "\n")
        let spine = chapterFiles.indices.map { #"        <itemref idref="c\#($0 + 1)"/>"# }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(metadata)  </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="css" href="style.css" media-type="text/css"/>\(coverItem(document))
            \(manifest)
              </manifest>
              <spine>
            \(spine)
              </spine>
            </package>
            """
    }

    /// The image's extension and media type, from its magic bytes.
    static func imageType(_ data: Data) -> (ext: String, mediaType: String)? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return ("jpg", "image/jpeg") }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("png", "image/png") }
        if data.starts(with: Array("GIF8".utf8)) { return ("gif", "image/gif") }
        return nil
    }

    private static func coverItem(_ document: EPUBDocument) -> String {
        guard let cover = document.coverImage, let type = imageType(cover) else { return "" }
        return "\n" + #"        <item id="cover" href="cover.\#(type.ext)" media-type="\#(type.mediaType)" properties="cover-image"/>"#
    }

    static func navigation(_ document: EPUBDocument, chapters: [EPUBDocument.Chapter], files: [String]) -> String {
        var entries = zip(chapters, files).compactMap { chapter, file in
            chapter.title.map { #"<li><a href="\#(file)">\#(XHTML.escape($0))</a></li>"# }
        }
        // The table of contents can't be empty; point at the start.
        if chapters.first?.title == nil {
            entries.insert(#"<li><a href="\#(files[0])">\#(XHTML.escape(document.title))</a></li>"#, at: 0)
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(XHTML.escape(document.language))" xml:lang="\(XHTML.escape(document.language))">
            <head><meta charset="UTF-8"/><title>\(XHTML.escape(document.title))</title></head>
            <body>
            <nav epub:type="toc" id="toc"><ol>
            \(entries.joined(separator: "\n"))
            </ol></nav>
            </body>
            </html>
            """
    }

    static func page(_ chapter: EPUBDocument.Chapter, bookTitle: String, language: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(XHTML.escape(language))" xml:lang="\(XHTML.escape(language))">
        <head><meta charset="UTF-8"/><title>\(XHTML.escape(chapter.title ?? bookTitle))</title><link rel="stylesheet" type="text/css" href="../style.css"/></head>
        <body>
        <section epub:type="chapter">
        \(chapter.body)
        </section>
        </body>
        </html>
        """
    }

    /// Kept minimal: the reader's own settings (font, size, spacing) win.
    static let stylesheet = """
        p { margin: 0 0 0.8em; }
        h2 { margin: 1.5em 0 1em; }
        hr.scene-break { border: none; text-align: center; margin: 1.5em 0; }
        hr.scene-break::after { content: "* * *"; }
        pre { white-space: pre-wrap; }
        blockquote { margin: 0 1.5em 0.8em; }
        """
}
