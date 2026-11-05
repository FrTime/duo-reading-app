import Foundation
import WebKit

/// Keeps books from reaching the network.
///
/// EPUBs can reference images, fonts or scripts on the web (AO3 downloads
/// often embed images hosted elsewhere). Loading them would tell those hosts
/// what someone is reading, so the reader's web views get a content rule list
/// that blocks every http and https load. Book content is served from
/// Readium's own `readium://` scheme and isn't affected.
@MainActor
enum RemoteContentBlocker {
    static let identifier = "duoreader.block-remote-content.v1"

    /// The WebKit content-blocker rules, as JSON.
    static let rulesJSON = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
    """

    private static var ruleList: WKContentRuleList?

    /// Compiles the rule list once. Call before building a navigator.
    static func prepare() async {
        guard ruleList == nil, let store = WKContentRuleListStore.default() else { return }
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
            ruleList = cached
            return
        }
        ruleList = try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rulesJSON)
    }

    /// Adds the rules to a web view's content controller.
    static func install(in controller: WKUserContentController) {
        guard let ruleList else { return }
        controller.add(ruleList)
    }
}

/// Which links in a book may leave the app.
enum ExternalLinkPolicy {
    /// Web pages and email only. Other schemes (`tel:`, `sms:`, other apps'
    /// custom schemes) could start calls or hand data to other apps from a
    /// link the reader can't see the target of.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }
}
