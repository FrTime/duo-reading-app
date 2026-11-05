import Foundation
import UIKit
import ReadiumZIPFoundation

/// Builds small test books on disk so no real (copyrighted) files live in the repo.
enum Fixtures {
    static func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "DuoReaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: name)
    }

    /// Writes an EPUB with the given files. `mimetype` and `container.xml`
    /// are added unless provided.
    static func epub(_ files: [String: Data], name: String = "book.epub", opfPath: String = "OEBPS/content.opf") async throws -> URL {
        let url = temporaryURL(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let archive = try await Archive(url: url, accessMode: .create)
        var all = files
        if all["mimetype"] == nil { all["mimetype"] = Data("application/epub+zip".utf8) }
        if all["META-INF/container.xml"] == nil {
            all["META-INF/container.xml"] = Data("""
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8)
        }
        // mimetype must be first and stored, as in a real EPUB.
        let order = ["mimetype"] + all.keys.filter { $0 != "mimetype" }.sorted()
        for path in order {
            let data = all[path]!
            try await archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: path == "mimetype" ? .none : .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return url
    }

    static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    /// A PDF with the given info dictionary and one page.
    static func pdf(title: String? = nil, author: String? = nil, subject: String? = nil, keywords: [String]? = nil) throws -> URL {
        let url = temporaryURL("doc.pdf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = UIGraphicsPDFRendererFormat()
        var info: [String: Any] = [:]
        if let title { info[kCGPDFContextTitle as String] = title }
        if let author { info[kCGPDFContextAuthor as String] = author }
        if let subject { info[kCGPDFContextSubject as String] = subject }
        if let keywords { info[kCGPDFContextKeywords as String] = keywords }
        format.documentInfo = info
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 450), format: format)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 450))
        }
        return url
    }
}
