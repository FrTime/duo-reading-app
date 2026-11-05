import Foundation
import SwiftData
import Testing
@testable import DuoReader

/// Builds small MOBI files by hand, following the same format notes the converter does.
enum MOBIFixture {
    struct Options {
        var title = "Header Title"
        var authors = ["Ada Writer", "Bo Second"]
        var publisher: String? = "Small Press"
        var description: String? = "<p>A <b>short</b> book.</p>"
        var language: String? = "en"
        var cover: Data? = Fixtures.tinyPNG
        var compressed = false
        var encrypted = false
        var trailingEntries = false
        /// Overrides the compression type, e.g. 17480 for Huffman/CDIC.
        var compressionType: UInt16?
        var extraEXTH: [(UInt32, Data)] = []
    }

    static let mobi6HTML = """
    <html><head><guide></guide></head><body>
    <h1>Chapter One</h1><p>It was a <i>dark</i> night &amp; stormy.</p>
    <mbp:pagebreak/>
    <h1>Chapter Two</h1><p>Morning came.</p>
    </body></html>
    """

    /// A MOBI 6 book: one HTML stream.
    static func mobi6(html: String = mobi6HTML, _ options: Options = Options()) -> Data {
        database(mobi6Records(html: html, options))
    }

    static func mobi6Records(html: String = mobi6HTML, _ options: Options) -> [Data] {
        let text = Data(html.utf8)
        let textRecords = records(of: text, options)
        var images: [Data] = []
        if let cover = options.cover { images.append(cover) }
        let header = recordZero(textLength: text.count, textRecords: textRecords.count, version: 6,
                                firstImage: UInt32(1 + textRecords.count), kf8: nil, options)
        return [header] + textRecords + images
    }

    /// A KF8 (AZW3) book: two skeleton files with one fragment each, plus a CSS flow.
    static func kf8(_ options: Options = Options()) -> Data {
        database(kf8Records(options))
    }

    /// A "both" file: MOBI 6 records, BOUNDARY, then a KF8 book whose
    /// indexes count from its own header. EXTH 121 names the KF8 header.
    static func combined(boundary: Int? = nil) -> Data {
        var options = Options()
        options.cover = nil
        let kf8 = kf8Records(options)
        let mobi6Count = mobi6Records(options).count
        options.extraEXTH = [(121, be32(UInt32(boundary ?? mobi6Count + 1)))]
        return database(mobi6Records(options) + [Data("BOUNDARY".utf8)] + kf8)
    }

    static func kf8Records(_ options: Options) -> [Data] {
        let skeleton1 = #"<?xml version="1.0"?><html><head><title>p1</title></head><body aid="0"></body></html>"#
        let fragment1 = "<h1>Chapter One</h1><p>Hello from KF8.</p>"
        let skeleton2 = #"<html><head><title>p2</title></head><body aid="1"><div aid="2"></div></body></html>"#
        let fragment2 = "<h1>Chapter Two</h1><p>Goodbye.</p>"
        let css = "p { color: red; }"

        let s1 = 0
        let f1 = s1 + skeleton1.utf8.count
        let s2 = f1 + fragment1.utf8.count
        let f2 = s2 + skeleton2.utf8.count
        let flowEnd = f2 + fragment2.utf8.count
        let html = skeleton1 + fragment1 + skeleton2 + fragment2
        let raw = Data((html + css).utf8)
        // Fragments go just before the closing tag of the element they fill.
        let insert1 = s1 + skeleton1.components(separatedBy: "</body>")[0].utf8.count
        let insert2 = s2 + skeleton2.components(separatedBy: "</div>")[0].utf8.count

        let textRecords = records(of: raw, options)
        var fdst = Data("FDST".utf8) + be32(12) + be32(2)
        fdst += be32(0) + be32(UInt32(flowEnd)) + be32(UInt32(flowEnd)) + be32(UInt32(raw.count))

        let skel = index(tags: [(1, 1, 0x03, 0), (6, 2, 0x0C, 0)], entries: [
            ("SKEL0000000", 0x05, [1, s1, skeleton1.utf8.count]),
            ("SKEL0000001", 0x05, [1, s2, skeleton2.utf8.count]),
        ])
        let frag = index(tags: [(2, 1, 0x01, 0), (3, 1, 0x02, 0), (4, 1, 0x04, 0), (6, 2, 0x08, 0)], entries: [
            (String(insert1), 0x0F, [0, 0, 0, 0, fragment1.utf8.count]),
            (String(insert2), 0x0F, [0, 1, 1, 0, fragment2.utf8.count]),
        ])
        let fdstIndex = 1 + textRecords.count
        let kf8 = (fdst: UInt32(fdstIndex), skeleton: UInt32(fdstIndex + 1), fragment: UInt32(fdstIndex + 3))
        var images: [Data] = []
        if let cover = options.cover { images.append(cover) }
        let header = recordZero(textLength: raw.count, textRecords: textRecords.count, version: 8,
                                firstImage: UInt32(fdstIndex + 5), kf8: kf8, options)
        return [header] + textRecords + [fdst] + skel + frag + images
    }

    // MARK: - Pieces

    static func be16(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xFF)]) }
    static func be32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> (24 - 8 * $0)) & 0xFF) }) }

    /// Forward varint: the last byte carries the high bit.
    static func varint(_ value: Int) -> Data {
        var groups = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 { groups.insert(UInt8(rest & 0x7F), at: 0); rest >>= 7 }
        groups[groups.count - 1] |= 0x80
        return Data(groups)
    }

    /// PalmDOC "compression" that only uses literals and short raw runs, which
    /// still goes through the decompressor's literal paths.
    static func palmDOCLiterals(_ data: Data) -> Data {
        var out = Data()
        for byte in data {
            if byte == 0 || (0x09...0x7F).contains(byte) { out.append(byte) } else { out += [0x01, byte] }
        }
        return out
    }

    static func records(of text: Data, _ options: Options) -> [Data] {
        stride(from: 0, to: text.count, by: 4096).map { start in
            var record = text.subdata(in: start ..< min(start + 4096, text.count))
            if options.compressed { record = palmDOCLiterals(record) }
            // One TBS-style entry (3 bytes, size last) and a multibyte byte.
            if options.trailingEntries { record += Data([0x00]) + Data([0xAA, 0xBB, 0x83]) }
            return record
        }
    }

    static func recordZero(textLength: Int, textRecords: Int, version: UInt32, firstImage: UInt32,
                           kf8: (fdst: UInt32, skeleton: UInt32, fragment: UInt32)?, _ o: Options) -> Data {
        let headerLength = 0x108
        var r = Data(count: 16 + headerLength)
        func put(_ bytes: Data, _ offset: Int) { r.replaceSubrange(offset ..< offset + bytes.count, with: bytes) }
        put(be16(o.compressionType ?? (o.compressed ? 2 : 1)), 0)
        put(be32(UInt32(textLength)), 4)
        put(be16(UInt16(textRecords)), 8)
        put(be16(4096), 10)
        put(be16(o.encrypted ? 2 : 0), 12)
        put(Data("MOBI".utf8), 16)
        put(be32(UInt32(headerLength)), 20)
        put(be32(2), 24)
        put(be32(65001), 28)
        put(be32(version), 36)
        put(be32(firstImage), 0x6C)
        put(be32(0x50), 0x80)
        put(be16(o.trailingEntries ? 0x3 : 0), 0xF2)
        put(be32(kf8?.fdst ?? 0xFFFF_FFFF), 0xC0)
        put(be32(kf8?.fragment ?? 0xFFFF_FFFF), 0xF8)
        put(be32(kf8?.skeleton ?? 0xFFFF_FFFF), 0xFC)

        var exth: [(UInt32, Data)] = [(503, Data(o.title.utf8))]
        exth += o.authors.map { (100, Data($0.utf8)) }
        if let p = o.publisher { exth.append((101, Data(p.utf8))) }
        if let d = o.description { exth.append((103, Data(d.utf8))) }
        if let l = o.language { exth.append((524, Data(l.utf8))) }
        if o.cover != nil { exth.append((201, be32(0))) }
        exth += o.extraEXTH
        let body = exth.reduce(Data()) { $0 + be32($1.0) + be32(UInt32($1.1.count + 8)) + $1.1 }
        r += Data("EXTH".utf8) + be32(UInt32(12 + body.count)) + be32(UInt32(exth.count)) + body
        let name = Data("Full Name".utf8)
        put(be32(UInt32(r.count)), 0x54)
        put(be32(UInt32(name.count)), 0x58)
        r += name + Data(count: 2)
        return r
    }

    /// An INDX index: a header record with TAGX, then one data record.
    static func index(tags: [(UInt8, UInt8, UInt8, UInt8)], entries: [(String, UInt8, [Int])]) -> [Data] {
        func indxHeader(start: UInt32, count: UInt32) -> Data {
            // len, nul, type, gen, IDXT start, count, encoding, language, total, ordt, ligt, nligt, nctoc
            let fields: [UInt32] = [56, 0, 0, 0, start, count, 65001, 0xFFFF_FFFF, UInt32(entries.count), 0, 0, 0, 0]
            return fields.reduce(Data("INDX".utf8)) { $0 + be32($1) }
        }
        let rows = (tags + [(0, 0, 0, 1)]).reduce(Data()) { $0 + Data([$1.0, $1.1, $1.2, $1.3]) }
        let tagx = Data("TAGX".utf8) + be32(UInt32(12 + rows.count)) + be32(1) + rows
        let main = indxHeader(start: 0, count: 1) + tagx

        var block = Data()
        var positions: [Int] = []
        for (text, control, values) in entries {
            positions.append(56 + block.count)
            block += Data([UInt8(text.utf8.count)]) + Data(text.utf8) + Data([control])
            for value in values { block += varint(value) }
        }
        let idxt = 56 + block.count
        let data = indxHeader(start: UInt32(idxt), count: UInt32(entries.count)) + block
            + Data("IDXT".utf8) + positions.reduce(Data()) { $0 + be16(UInt16($1)) }
        return [main, data]
    }

    /// The Palm database around the records.
    static func database(_ records: [Data]) -> Data {
        var header = Data("Duo Fixture".utf8) + Data(count: 32 - 11)
        header += Data(count: 28)
        header += Data("BOOKMOBI".utf8) + Data(count: 8)
        header += be16(UInt16(records.count))
        var offset = header.count + records.count * 8 + 2
        var list = Data()
        for (i, record) in records.enumerated() {
            list += be32(UInt32(offset)) + be32(UInt32(i * 2))
            offset += record.count
        }
        return records.reduce(header + list + Data(count: 2), +)
    }
}

struct MOBIConverterTests {
    @Test func palmDOCDecompression() {
        // "abc", then copy 6 bytes from 3 back (overlapping).
        #expect(MOBIBook.palmDOCDecompress(Data([0x61, 0x62, 0x63, 0x80, 0x1B])) == Data("abcabcabc".utf8))
        // A space plus a character in one byte, and a raw run.
        #expect(MOBIBook.palmDOCDecompress(Data([0xE1, 0x02, 0xC3, 0xA9])) == Data([0x20, 0x61, 0xC3, 0xA9]))
        // A back-reference past the start is ignored, not a crash.
        #expect(MOBIBook.palmDOCDecompress(Data([0x80, 0x1B, 0x61])) == Data("a".utf8))
    }

    @Test func trailingEntriesAreTrimmed() {
        let record = Data("text".utf8) + Data([0x00]) + Data([0xAA, 0xBB, 0x83])
        #expect(MOBIBook.trimTrailingEntries(record, flags: 0x3) == Data("text".utf8))
        #expect(MOBIBook.trimTrailingEntries(Data("text".utf8), flags: 0) == Data("text".utf8))
        // Sizes larger than the record don't underflow.
        #expect(MOBIBook.trimTrailingEntries(Data([0xFF]), flags: 0x2).isEmpty)
    }

    @Test func mobi6MetadataChaptersAndCover() throws {
        let doc = try MOBIConverter.document(fromMOBI: MOBIFixture.mobi6(), fallbackTitle: "file")
        #expect(doc.title == "Header Title")
        #expect(doc.authors == ["Ada Writer", "Bo Second"])
        #expect(doc.publisher == "Small Press")
        #expect(doc.summary == "A short book.")
        #expect(doc.language == "en")
        #expect(doc.coverImage == Fixtures.tinyPNG)
        #expect(doc.chapters.map(\.title) == ["Chapter One", "Chapter Two"])
        #expect(doc.chapters[0].body.contains("<em>dark</em>") || doc.chapters[0].body.contains("<i>dark</i>"))
        #expect(!doc.chapters.map(\.body).joined().contains("mbp:"))
    }

    @Test(arguments: [(true, false), (false, true), (true, true)])
    func compressionAndTrailingEntries(compressed: Bool, trailing: Bool) throws {
        var options = MOBIFixture.Options()
        options.compressed = compressed
        options.trailingEntries = trailing
        // Long enough for several 4 KB text records.
        let long = String(repeating: "<p>All work and no play — café.</p>\n", count: 400)
        let html = "<html><body><h1>Only</h1>\(long)</body></html>"
        let doc = try MOBIConverter.document(fromMOBI: MOBIFixture.mobi6(html: html, options), fallbackTitle: "f")
        let body = doc.chapters.map(\.body).joined()
        #expect(body.components(separatedBy: "All work and no play — café.").count == 401)
    }

    @Test func titleFallsBackToTheFullName() throws {
        var options = MOBIFixture.Options()
        options.title = ""
        let doc = try MOBIConverter.document(fromMOBI: MOBIFixture.mobi6(options), fallbackTitle: "f")
        #expect(doc.title == "Full Name")
    }

    @Test func kf8SkeletonsAndFragmentsAreRebuilt() throws {
        let doc = try MOBIConverter.document(fromMOBI: MOBIFixture.kf8(), fallbackTitle: "file")
        #expect(doc.title == "Header Title")
        #expect(doc.chapters.map(\.title) == ["Chapter One", "Chapter Two"])
        let body = doc.chapters.map(\.body).joined()
        #expect(body.contains("Hello from KF8."))
        #expect(body.contains("Goodbye."))
        // The CSS flow and the skeleton heads stay out of the text.
        #expect(!body.contains("color: red"))
        #expect(!body.contains("p1"))
        #expect(doc.coverImage == Fixtures.tinyPNG)
    }

    @Test func combinedFilesPreferKF8AndFallBackToMOBI6() throws {
        let both = try MOBIConverter.document(fromMOBI: MOBIFixture.combined(), fallbackTitle: "f")
        let kf8Text = both.chapters.map(\.body).joined()
        #expect(kf8Text.contains("Hello from KF8."))
        #expect(!kf8Text.contains("Morning came."))

        // EXTH 121 pointing somewhere that isn't next to BOUNDARY: use the MOBI 6 text.
        let broken = try MOBIConverter.document(fromMOBI: MOBIFixture.combined(boundary: 1), fallbackTitle: "f")
        #expect(broken.chapters.map(\.body).joined().contains("Morning came."))
    }

    @Test func huffmanCompressionIsUnreadableForNow() {
        var options = MOBIFixture.Options()
        options.compressionType = 17480
        #expect(throws: ConversionError.unreadable) {
            _ = try MOBIConverter.document(fromMOBI: MOBIFixture.mobi6(options), fallbackTitle: "f")
        }
    }

    @Test func legacyEncodingWithUndefinedBytesStillDecodes() {
        // 0x81 isn't defined in Windows-1252; one stray byte mustn't sink the book.
        let header = MOBIBook.Header.decodeLegacy(Data([0x43, 0x61, 0x66, 0xE9, 0x81]))
        #expect(header.hasPrefix("Café"))
    }

    @Test func encryptedBooksAreReportedAsDRM() {
        var options = MOBIFixture.Options()
        options.encrypted = true
        #expect(throws: ConversionError.drmProtected) {
            _ = try MOBIConverter.document(fromMOBI: MOBIFixture.mobi6(options), fallbackTitle: "f")
        }
        #expect(throws: ConversionError.drmProtected) {
            _ = try MOBIConverter.document(fromMOBI: Data([0xEA] + Array("DRMION".utf8) + [0, 0]), fallbackTitle: "f")
        }
    }

    @Test func otherFilesAreUnreadable() {
        #expect(throws: ConversionError.unreadable) {
            _ = try MOBIConverter.document(fromMOBI: Data("not a mobi".utf8), fallbackTitle: "f")
        }
        // Truncated: the record list points past the end.
        let truncated = MOBIFixture.mobi6().prefix(200)
        #expect(throws: ConversionError.unreadable) {
            _ = try MOBIConverter.document(fromMOBI: Data(truncated), fallbackTitle: "f")
        }
    }

    @Test func wellFormedOutput() throws {
        for data in [MOBIFixture.mobi6(), MOBIFixture.kf8()] {
            let doc = try MOBIConverter.document(fromMOBI: data, fallbackTitle: "f")
            for (path, file) in EPUBWriter.files(for: doc) where path.hasSuffix(".xhtml") || path.hasSuffix(".opf") {
                #expect(XMLParser(data: file).parse(), "\(path) isn't well-formed")
            }
        }
    }
}

@MainActor
struct MOBIImportTests {
    @Test func importsMOBIAndAZW3AndExplainsDRM() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let importer = LibraryImporter(modelContainer: container, booksFolder: Fixtures.temporaryURL("Books"))
        let folder = Fixtures.temporaryURL("mobi")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let mobi = folder.appending(path: "one.mobi")
        try MOBIFixture.mobi6().write(to: mobi)
        var kf8Options = MOBIFixture.Options()
        kf8Options.title = "KF8 Title"
        let azw3 = folder.appending(path: "two.azw3")
        try MOBIFixture.kf8(kf8Options).write(to: azw3)
        var locked = MOBIFixture.Options()
        locked.encrypted = true
        let drm = folder.appending(path: "locked.azw")
        try MOBIFixture.mobi6(locked).write(to: drm)

        guard case .imported = await importer.importFile(mobi) else { Issue.record("mobi"); return }
        guard case .imported = await importer.importFile(azw3) else { Issue.record("azw3"); return }
        #expect(await importer.importFile(drm) == .failed(fileName: "locked.azw", reason: .drmProtected))

        let books = try container.mainContext.fetch(FetchDescriptor<Book>(sortBy: [SortDescriptor(\.shelfOrder)]))
        #expect(books.map(\.title) == ["Header Title", "KF8 Title"])
        #expect(books.allSatisfy { $0.format == .epub && $0.coverImageData != nil })
        #expect(Set(LibraryImporter.supportedFormats).isSuperset(of: [.mobi, .azw3]))
    }
}
