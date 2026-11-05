import Foundation
@preconcurrency import ReadiumShared

/// One row of the table of contents.
struct TOCEntry: Identifiable, Equatable {
    let id: Int
    let title: String
    let link: Link
    /// Nesting level, 0 for top-level chapters.
    let depth: Int

    /// The resource part of the link, without any `#fragment`, to match
    /// against the current position.
    var resourceHref: String {
        link.url().string.split(separator: "#", maxSplits: 1).first.map(String.init) ?? link.href
    }

    /// The entry the reader is in.
    ///
    /// Entries are matched to the reading order, so a chapter that spans
    /// several files stays current until the next listed one starts. Within
    /// one file, the first entry for it (the chapter rather than a later
    /// section) is chosen.
    ///
    /// - Parameters:
    ///   - readingOrder: The book's resource paths in reading order.
    ///   - current: The current resource path.
    static func currentID(in entries: [TOCEntry], readingOrder: [String], current: String) -> ID? {
        let order = readingOrder.map(normalized)
        guard let here = order.firstIndex(of: normalized(current)) else {
            return entries.first { normalized($0.resourceHref) == normalized(current) }?.id
        }
        var best: (index: Int, id: ID)?
        for entry in entries {
            guard let index = order.firstIndex(of: normalized(entry.resourceHref)), index <= here else { continue }
            if index == here {
                // The first entry for the current file wins.
                if best?.index != here { best = (index, entry.id) }
            } else if best?.index != here, index >= (best?.index ?? 0) {
                // Before the current file: the latest one, so a chapter that
                // spans files stays current.
                best = (index, entry.id)
            }
        }
        return best?.id
    }

    /// A path without its fragment or percent-encoding, for comparing.
    static func normalized(_ href: String) -> String {
        let path = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        return path.removingPercentEncoding ?? path
    }

    /// Flattens nested contents depth-first, numbering rows in reading order.
    /// Entries without a title get "Untitled".
    static func flatten(_ links: [Link]) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        func visit(_ links: [Link], depth: Int) {
            for link in links {
                let title = link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(TOCEntry(
                    id: entries.count,
                    title: (title?.isEmpty == false ? title : nil) ?? String(localized: "Untitled"),
                    link: link,
                    depth: depth
                ))
                visit(link.children, depth: depth + 1)
            }
        }
        visit(links, depth: 0)
        return entries
    }
}
