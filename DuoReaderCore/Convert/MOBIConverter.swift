import Foundation
import SwiftSoup

/// Converts Kindle books (`.mobi`, `.prc`, `.azw`, `.azw3`) that aren't
/// DRM-protected, such as AO3's MOBI and AZW3 downloads and Calibre output.
///
/// Both generations of the format are read:
/// - MOBI 6 ("MOBI 7" in Calibre): one HTML stream with `<mbp:pagebreak/>`s.
/// - KF8 (AZW3, and the second half of "both" MOBI files): HTML split into
///   skeleton files with fragments to insert, rebuilt here from the SKEL and
///   FRAG indexes. KF8 is preferred when a file has both.
///
/// Each KF8 file, or each stretch of MOBI 6 text between page breaks, is
/// cleaned the same way as an HTML import and starts a new chapter, so books
/// whose chapters have no heading still get one file per chapter. The EXTH header supplies
/// the title, authors, publisher, description, language and cover.
///
/// Written from the public format descriptions (MobileRead wiki) rather than
/// using libmobi, whose LGPL licence is awkward for App Store builds.
/// Huffman/CDIC-compressed text (some Amazon-made files) isn't read yet.
public struct MOBIConverter: BookConverter {
    public init() {}

    /// MOBI files carry their images, so they're allowed to be bigger than text formats.
    static let maxFileBytes = 200 * 1024 * 1024

    public func document(from url: URL) async throws -> EPUBDocument {
        let data = try BookConverters.readSource(url, limit: Self.maxFileBytes)
        return try Self.document(fromMOBI: data, fallbackTitle: BookConverters.title(for: url))
    }

    static func document(fromMOBI data: Data, fallbackTitle: String) throws -> EPUBDocument {
        let book = try MOBIBook(data)
        var chapters: [EPUBDocument.Chapter] = []
        var sample = ""
        do {
            for part in book.parts {
                guard let body = try HTMLConverter.xhtmlFragment(part).body() else { continue }
                let blocks = try HTMLConverter.blocks(in: HTMLConverter.contentRoot(of: body))
                guard !blocks.isEmpty else { continue }
                if sample.utf8.count < 4000 { sample += try body.text() + " " }
                let levels = blocks.compactMap { if case .heading(let level, _) = $0 { level } else { nil } }
                chapters += TextBlock.chapters(from: blocks, splitLevel: levels.min())
            }
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.unreadable
        }
        guard !chapters.isEmpty else { throw ConversionError.unreadable }

        var document = EPUBDocument(title: book.title ?? fallbackTitle, authors: book.authors, chapters: chapters)
        document.publisher = book.publisher
        if let description = book.description {
            let plain = (try? SwiftSoup.parseBodyFragment(description).text()) ?? description
            document.summary = plain.isEmpty ? nil : plain
        }
        document.language = book.language ?? BookConverters.detectLanguage(sample) ?? "en"
        if let cover = book.cover, EPUBWriter.imageType(cover) != nil { document.coverImage = cover }
        return document
    }
}

/// A parsed Palm database holding a MOBI book.
struct MOBIBook {
    /// The book's HTML, as the insides of one `<body>` per part.
    var parts: [String] = []
    var title: String?
    var authors: [String] = []
    var publisher: String?
    var description: String?
    var language: String?
    var cover: Data?

    private let data: Data
    private var offsets: [Int] = []

    init(_ data: Data) throws {
        self.data = data
        // KFX files are a different container; the DRM'd ones say so up front.
        if data.starts(with: [0xEA] + Array("DRMION".utf8)) { throw ConversionError.drmProtected }
        guard data.count >= 78, data.byteArray(at: 60, count: 8) == Array("BOOKMOBI".utf8),
              let count = data.uint16BE(at: 76), count > 1, data.count >= 78 + Int(count) * 8 else {
            throw ConversionError.unreadable
        }
        offsets = (0..<Int(count)).compactMap { data.uint32BE(at: 78 + $0 * 8).map(Int.init) }
        guard offsets.count == Int(count), zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }),
              let last = offsets.last, last <= data.count else {
            throw ConversionError.unreadable
        }

        let header = try Header(record(0))
        let exth = header.exth
        title = exth[503]?.first.flatMap(header.string) ?? header.fullName
        authors = (exth[100] ?? []).compactMap(header.string)
        publisher = exth[101]?.first.flatMap(header.string)
        description = exth[103]?.first.flatMap(header.string)
        language = exth[524]?.first.flatMap(header.string)
        if let offset = exth[201]?.first?.uint32BE(at: 0), offset != 0xFFFF_FFFF, header.firstImage != 0xFFFF_FFFF {
            cover = try? record(Int(header.firstImage) + Int(offset))
        }

        // A "both" file has a KF8 book after a BOUNDARY record.
        if header.version >= 8 {
            parts = try kf8Parts(header: header, start: 0)
        } else if let boundary = exth[121]?.first?.uint32BE(at: 0).map(Int.init), boundary != 0xFFFF_FFFF,
                  boundary < offsets.count,
                  let kf8 = try? kf8Start(boundary),
                  let rebuilt = try? kf8Parts(header: Header(record(kf8)), start: kf8) {
            parts = rebuilt
        } else {
            guard let page = header.string(try text(header: header, start: 0)) else { throw ConversionError.unreadable }
            parts = Self.splitAtPageBreaks(Self.bodyContents(page))
        }
    }

    /// The KF8 header is the record after BOUNDARY (which EXTH 121 sometimes names itself).
    private func kf8Start(_ boundary: Int) throws -> Int {
        let marker = Array("BOUNDARY".utf8)
        if try record(boundary).starts(with: marker) { return boundary + 1 }
        if boundary > 0, try record(boundary - 1).starts(with: marker) { return boundary }
        throw ConversionError.unreadable
    }

    func record(_ index: Int) throws -> Data {
        guard index >= 0, index < offsets.count else { throw ConversionError.unreadable }
        let end = index + 1 < offsets.count ? offsets[index + 1] : data.count
        return data.subdata(in: data.startIndex + offsets[index] ..< data.startIndex + end)
    }

    // MARK: - Text

    /// The book's decompressed text, every flow included.
    private func text(header: Header, start: Int) throws -> Data {
        guard header.encrypted == false else { throw ConversionError.drmProtected }
        guard header.textLength <= BookConverters.maxHTMLBytes else { throw ConversionError.tooLarge }
        var text = Data()
        text.reserveCapacity(header.textLength)
        for index in 1...max(1, header.textRecordCount) where header.textRecordCount > 0 {
            let raw = Self.trimTrailingEntries(try record(start + index), flags: header.extraFlags)
            switch header.compression {
            case 1: text.append(raw)
            case 2: text.append(Self.palmDOCDecompress(raw))
            default: throw ConversionError.unreadable
            }
            guard text.count <= BookConverters.maxHTMLBytes else { throw ConversionError.tooLarge }
        }
        return text.prefix(header.textLength)
    }

    /// Text records can end with extra entries (multibyte character overlap,
    /// TBS indexing data) that aren't part of the text.
    static func trimTrailingEntries(_ record: Data, flags: UInt16) -> Data {
        var bytes = record
        var trailers = flags >> 1
        while trailers != 0 {
            if trailers & 1 == 1 {
                // A backward varint: the byte with the high bit set starts it.
                var size = 0
                for byte in bytes.suffix(4) {
                    if byte & 0x80 != 0 { size = 0 }
                    size = (size << 7) | Int(byte & 0x7F)
                }
                bytes = bytes.dropLast(min(size, bytes.count))
            }
            trailers >>= 1
        }
        if flags & 1 == 1, let last = bytes.last {
            bytes = bytes.dropLast(min(Int(last & 3) + 1, bytes.count))
        }
        return Data(bytes)
    }

    /// PalmDOC's LZ77 variant.
    static func palmDOCDecompress(_ input: Data) -> Data {
        let bytes = [UInt8](input)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            i += 1
            switch c {
            case 1...8:
                let end = min(i + Int(c), bytes.count)
                out += bytes[i..<end]
                i = end
            case 0x00...0x7F:
                out.append(c)
            case 0xC0...0xFF:
                out.append(0x20)
                out.append(c ^ 0x80)
            default:
                guard i < bytes.count else { break }
                let pair = (Int(c) << 8) | Int(bytes[i])
                i += 1
                let distance = (pair & 0x3FFF) >> 3
                let length = (pair & 7) + 3
                guard distance > 0, distance <= out.count else { continue }
                // Byte by byte: the copy may overlap what it's writing.
                for _ in 0..<length { out.append(out[out.count - distance]) }
            }
        }
        return Data(out)
    }

    // MARK: - KF8

    /// MOBI 6 marks the start of each original file with a page break.
    static func splitAtPageBreaks(_ html: String) -> [String] {
        html.split(separator: /<mbp:pagebreak[^>]*>|<\/mbp:pagebreak>/.ignoresCase()).map(String.init)
    }

    /// Rebuilds KF8's XHTML files, returning each one's body.
    private func kf8Parts(header: Header, start: Int) throws -> [String] {
        var raw = try text(header: header, start: start)
        // Flow 0 is the HTML; the other flows are CSS and SVG.
        if header.fdst != 0xFFFF_FFFF, let fdst = try? record(start + Int(header.fdst)),
           fdst.starts(with: Array("FDST".utf8)), let count = fdst.uint32BE(at: 8), count > 0,
           let from = fdst.uint32BE(at: 12).map(Int.init), let to = fdst.uint32BE(at: 16).map(Int.init),
           from <= to, to <= raw.count {
            raw = raw.subdata(in: from..<to)
        }
        let rawBytes = [UInt8](raw)

        guard header.skeletonIndex != 0xFFFF_FFFF, header.fragmentIndex != 0xFFFF_FFFF else {
            // Without indexes the text is already one page.
            guard let page = header.string(raw) else { throw ConversionError.unreadable }
            return [Self.bodyContents(page)]
        }
        let skeletons = try index(start + Int(header.skeletonIndex)).map { entry -> (fragments: Int, start: Int, length: Int) in
            guard let count = entry.tags[1]?.first, let position = entry.tags[6], position.count >= 2 else {
                throw ConversionError.unreadable
            }
            return (count, position[0], position[1])
        }
        let fragments = try index(start + Int(header.fragmentIndex)).map { entry -> (insert: Int, length: Int) in
            guard let insert = Int(String(decoding: entry.text, as: UTF8.self)),
                  let position = entry.tags[6], position.count >= 2 else { throw ConversionError.unreadable }
            return (insert, position[1])
        }

        var bodies: [String] = []
        var next = 0
        for skeleton in skeletons {
            guard skeleton.start >= 0, skeleton.start + skeleton.length <= rawBytes.count else { throw ConversionError.unreadable }
            var file = Array(rawBytes[skeleton.start ..< skeleton.start + skeleton.length])
            var cursor = skeleton.start + skeleton.length
            for _ in 0..<skeleton.fragments {
                guard next < fragments.count else { throw ConversionError.unreadable }
                let fragment = fragments[next]
                next += 1
                let insert = fragment.insert - skeleton.start
                guard insert >= 0, insert <= file.count, cursor + fragment.length <= rawBytes.count else {
                    throw ConversionError.unreadable
                }
                file.insert(contentsOf: rawBytes[cursor ..< cursor + fragment.length], at: insert)
                cursor += fragment.length
            }
            guard let page = header.string(Data(file)) else { throw ConversionError.unreadable }
            bodies.append(Self.bodyContents(page))
        }
        return bodies
    }

    /// What's between `<body …>` and `</body>`, or the whole page if it has no body tags.
    static func bodyContents(_ page: String) -> String {
        guard let open = page.range(of: "<body", options: .caseInsensitive),
              let openEnd = page[open.upperBound...].firstIndex(of: ">") else { return page }
        let rest = page[page.index(after: openEnd)...]
        let close = rest.range(of: "</body>", options: [.caseInsensitive, .backwards])?.lowerBound ?? rest.endIndex
        return String(rest[..<close])
    }

    struct IndexEntry {
        var text: Data
        var tags: [UInt8: [Int]]
    }

    /// Reads an INDX index: a header record with the tag table, then data records.
    func index(_ first: Int) throws -> [IndexEntry] {
        let main = try record(first)
        guard main.starts(with: Array("INDX".utf8)), let headerLength = main.uint32BE(at: 4).map(Int.init),
              let recordCount = main.uint32BE(at: 24).map(Int.init), recordCount < 10_000 else {
            throw ConversionError.unreadable
        }
        // TAGX: control byte count, then (tag, values per entry, mask, end flag) rows.
        guard main.byteArray(at: headerLength, count: 4) == Array("TAGX".utf8),
              let tagxLength = main.uint32BE(at: headerLength + 4).map(Int.init),
              let controlBytes = main.uint32BE(at: headerLength + 8).map(Int.init) else {
            throw ConversionError.unreadable
        }
        var table: [(tag: UInt8, perEntry: Int, mask: UInt8, end: Bool)] = []
        for offset in stride(from: 12, to: tagxLength, by: 4) {
            guard let row = main.byteArray(at: headerLength + offset, count: 4) else { throw ConversionError.unreadable }
            table.append((row[0], Int(row[1]), row[2], row[3] == 1))
        }

        var entries: [IndexEntry] = []
        for index in first + 1 ... first + max(recordCount, 1) where recordCount > 0 {
            let bytes = [UInt8](try record(index))
            let block = Data(bytes)
            guard block.starts(with: Array("INDX".utf8)), let idxt = block.uint32BE(at: 20).map(Int.init),
                  let count = block.uint32BE(at: 24).map(Int.init) else { throw ConversionError.unreadable }
            var positions = try (0..<count).map { j in
                guard let position = block.uint16BE(at: idxt + 4 + 2 * j) else { throw ConversionError.unreadable }
                return Int(position)
            }
            positions.append(idxt)
            for j in 0..<count {
                let start = positions[j], end = positions[j + 1]
                guard start < end, end <= bytes.count else { throw ConversionError.unreadable }
                let textLength = Int(bytes[start])
                guard start + 1 + textLength <= end else { throw ConversionError.unreadable }
                let text = Data(bytes[start + 1 ..< start + 1 + textLength])
                let tags = try Self.tagValues(bytes, from: start + 1 + textLength, to: end, controlBytes: controlBytes, table: table)
                entries.append(IndexEntry(text: text, tags: tags))
            }
        }
        return entries
    }

    /// Decodes one index entry's tag values from its control bytes.
    static func tagValues(_ bytes: [UInt8], from start: Int, to end: Int, controlBytes: Int,
                          table: [(tag: UInt8, perEntry: Int, mask: UInt8, end: Bool)]) throws -> [UInt8: [Int]] {
        var cursor = start + controlBytes
        var controlIndex = 0
        var pending: [(tag: UInt8, count: Int?, byteLength: Int?, perEntry: Int)] = []
        for row in table {
            if row.end { controlIndex += 1; continue }
            guard start + controlIndex < end else { throw ConversionError.unreadable }
            var value = bytes[start + controlIndex] & row.mask
            guard value != 0 else { continue }
            if value == row.mask, row.mask.nonzeroBitCount > 1 {
                // All bits set: a varint of how many *bytes* of values follow.
                let (length, used) = try forwardVarint(bytes, at: cursor, end: end)
                cursor += used
                pending.append((row.tag, nil, length, row.perEntry))
            } else {
                var mask = row.mask
                while mask & 1 == 0 { mask >>= 1; value >>= 1 }
                pending.append((row.tag, Int(value), nil, row.perEntry))
            }
        }
        var tags: [UInt8: [Int]] = [:]
        for item in pending {
            var values: [Int] = []
            if let count = item.count {
                for _ in 0 ..< count * item.perEntry {
                    let (value, used) = try forwardVarint(bytes, at: cursor, end: end)
                    cursor += used
                    values.append(value)
                }
            } else if let byteLength = item.byteLength {
                var consumed = 0
                while consumed < byteLength {
                    let (value, used) = try forwardVarint(bytes, at: cursor, end: end)
                    cursor += used
                    consumed += used
                    values.append(value)
                }
            }
            tags[item.tag] = values
        }
        return tags
    }

    /// A forward varint: seven bits per byte, the last byte has its high bit set.
    static func forwardVarint(_ bytes: [UInt8], at start: Int, end: Int) throws -> (value: Int, length: Int) {
        var value = 0
        var index = start
        while index < end, index - start < 5 {
            let byte = bytes[index]
            index += 1
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 != 0 { return (value, index - start) }
        }
        throw ConversionError.unreadable
    }

    // MARK: - Header

    /// Record 0: the PalmDOC header, the MOBI header and the EXTH metadata.
    struct Header {
        var compression: UInt16
        var textLength: Int
        var textRecordCount: Int
        var encrypted: Bool
        var utf8: Bool
        var version: UInt32
        var firstImage: UInt32
        var extraFlags: UInt16 = 0
        var fdst: UInt32 = 0xFFFF_FFFF
        var fragmentIndex: UInt32 = 0xFFFF_FFFF
        var skeletonIndex: UInt32 = 0xFFFF_FFFF
        var fullName: String?
        var exth: [UInt32: [Data]] = [:]

        init(_ record: Data) throws {
            guard let compression = record.uint16BE(at: 0), let textLength = record.uint32BE(at: 4),
                  let textRecords = record.uint16BE(at: 8), let encryption = record.uint16BE(at: 12),
                  record.byteArray(at: 16, count: 4) == Array("MOBI".utf8),
                  let headerLength = record.uint32BE(at: 20).map(Int.init),
                  let encoding = record.uint32BE(at: 28) else {
                throw ConversionError.unreadable
            }
            self.compression = compression
            self.textLength = Int(textLength)
            textRecordCount = Int(textRecords)
            encrypted = encryption != 0
            utf8 = encoding == 65001
            version = record.uint32BE(at: 36) ?? 0
            firstImage = record.uint32BE(at: 0x6C) ?? 0xFFFF_FFFF
            // Fields past the end of a short header don't exist in that file.
            let end = 16 + headerLength
            if end >= 0xF4 { extraFlags = record.uint16BE(at: 0xF2) ?? 0 }
            if version >= 8 {
                if end >= 0xC4 { fdst = record.uint32BE(at: 0xC0) ?? fdst }
                if end >= 0xFC { fragmentIndex = record.uint32BE(at: 0xF8) ?? fragmentIndex }
                if end >= 0x100 { skeletonIndex = record.uint32BE(at: 0xFC) ?? skeletonIndex }
            }

            if let flags = record.uint32BE(at: 0x80), flags & 0x40 != 0,
               record.byteArray(at: end, count: 4) == Array("EXTH".utf8),
               let count = record.uint32BE(at: end + 8) {
                var offset = end + 12
                for _ in 0 ..< min(Int(count), 1000) {
                    guard let type = record.uint32BE(at: offset), let length = record.uint32BE(at: offset + 4).map(Int.init),
                          length >= 8, let value = record.byteArray(at: offset + 8, count: length - 8) else { break }
                    exth[type, default: []].append(Data(value))
                    offset += length
                }
            }
            if let offset = record.uint32BE(at: 0x54).map(Int.init), let length = record.uint32BE(at: 0x58).map(Int.init),
               length > 0, let name = record.byteArray(at: offset, count: length) {
                fullName = string(Data(name))
            }
        }

        /// Text in the book's declared encoding, trimmed, or nil when empty.
        func string(_ data: Data) -> String? {
            let text = utf8 ? String(decoding: data, as: UTF8.self) : Self.decodeLegacy(data)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            return trimmed.isEmpty ? nil : trimmed
        }

        /// Windows-1252, falling back to Latin-1 (which maps every byte) when
        /// the text has bytes 1252 leaves undefined, such as 0x81.
        static func decodeLegacy(_ data: Data) -> String {
            String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
    }
}

fileprivate extension Data {
    /// `count` bytes at `offset` from the start, or nil when they run past the end.
    func byteArray(at offset: Int, count: Int) -> [UInt8]? {
        guard offset >= 0, count >= 0, offset + count <= self.count else { return nil }
        return [UInt8](self[startIndex + offset ..< startIndex + offset + count])
    }

    func uint16BE(at offset: Int) -> UInt16? {
        byteArray(at: offset, count: 2).map { UInt16($0[0]) << 8 | UInt16($0[1]) }
    }

    func uint32BE(at offset: Int) -> UInt32? {
        byteArray(at: offset, count: 4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
    }
}
