import Foundation

/// Free-text image search in a web view, for covers that only the open web
/// has (fan-made covers on Tumblr, AO3 and the like). Nothing is sent until
/// the user searches, and the web view keeps no cookies or history.
public enum WebImageSearch {
    /// The provider name stored in `CoverImageSource.search` for web picks.
    public static let providerName = "web"

    /// A starting query for a book: its title, first author and "book cover".
    public static func defaultQuery(title: String, authors: [String]) -> String {
        let parts = [title.trimmingCharacters(in: .whitespacesAndNewlines), authors.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""]
            .filter { !$0.isEmpty }
        return (parts + ["book cover"]).joined(separator: " ")
    }

    /// The image results page for a query, or nil when the query is blank.
    public static func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.bing.com/images/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "safeSearch", value: "Moderate"),
        ]
        return components?.url
    }

    /// One way to get the image the user tapped, best first.
    public enum Candidate: Equatable, Sendable {
        case remote(URL)
        /// A `data:` image already in the page, such as a lazy thumbnail.
        case inline(Data)
    }

    /// Turns what the page script reports for a tapped image into download
    /// candidates: the full-size image when the results page knows it, then
    /// the image as shown. Only HTTPS and inline images are kept.
    public static func candidates(full: String?, shown: String?) -> [Candidate] {
        var result: [Candidate] = []
        for string in [full, shown].compactMap({ $0 }) {
            guard let candidate = candidate(from: string), !result.contains(candidate) else { continue }
            result.append(candidate)
        }
        return result
    }

    static func candidate(from string: String) -> Candidate? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("data:image/") {
            guard let comma = trimmed.firstIndex(of: ","),
                  trimmed[..<comma].lowercased().hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(trimmed[trimmed.index(after: comma)...]))
            else { return nil }
            return .inline(data)
        }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return .remote(url)
    }

    /// Injected into every page. A tap on an image is reported to the app
    /// instead of following its link. On image results pages the full-size
    /// address is read from the result's metadata.
    public static let pickScript = """
    (function() {
      if (window.__duoCoverPick) { return; }
      window.__duoCoverPick = true;
      function fullURL(img) {
        for (var node = img; node; node = node.parentElement) {
          var m = node.getAttribute && node.getAttribute('m');
          if (m) { try { var meta = JSON.parse(m); if (meta.murl) { return meta.murl; } } catch (e) {} }
          if (node.tagName === 'A') {
            var href = node.getAttribute('href') || '';
            if (/\\.(jpe?g|png|webp|gif)(\\?|$)/i.test(href)) { return new URL(href, location.href).href; }
          }
        }
        return null;
      }
      document.addEventListener('click', function(event) {
        var img = event.target.closest && event.target.closest('img');
        if (!img) { return; }
        var rect = img.getBoundingClientRect();
        if (rect.width < 40 || rect.height < 40) { return; }
        event.preventDefault();
        event.stopPropagation();
        window.webkit.messageHandlers.coverPick.postMessage({
          full: fullURL(img),
          shown: img.currentSrc || img.src || null
        });
      }, true);
    })();
    """
}
