import Foundation

/// Detects X's official Paid partnership / content-disclosure label.
///
/// Only article chrome is considered — never the long-form body — so an
/// educational article that happens to mention the policy is not tagged.
public enum PaidPartnershipDetector {
    public static func isPaidPartnership(
        chromeText: String,
        linkURLs: [String] = [],
        testIDs: [String] = []
    ) -> Bool {
        if testIDs.contains(where: isPartnershipTestID) { return true }
        if linkURLs.contains(where: isPartnershipHelpURL) { return true }
        return containsPartnershipLabel(chromeText)
    }

    public static func containsPartnershipLabel(_ chromeText: String) -> Bool {
        let lines = chromeText
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.contains(where: isExactDisclosureLine) { return true }

        let collapsed = normalize(chromeText)
        let looksLikeCompactHeader = lines.count <= 8
            && lines.allSatisfy { $0.count <= 80 }
            && collapsed.count <= 240
            && !looksLikeProse(chromeText)
        guard looksLikeCompactHeader else { return false }
        return labels.contains { collapsed.contains($0) }
    }

    private static func isExactDisclosureLine(_ line: String) -> Bool {
        let normalized = normalize(line)
        return labels.contains { label in
            if normalized == label { return true }
            let suffixes = [" with ", " with @", " con ", " avec ", " mit ", " com "]
            return suffixes.contains { suffix in
                normalized.hasPrefix(label + suffix) && normalized.count <= label.count + 40
            }
        }
    }

    private static func looksLikeProse(_ text: String) -> Bool {
        if text.contains("。") || text.contains("？") || text.contains("！") { return true }
        if text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") { return true }
        return text.contains(". ") || text.contains("! ") || text.contains("? ")
    }

    private static func isPartnershipTestID(_ value: String) -> Bool {
        let folded = value
            .lowercased()
            .replacingOccurrences(of: "[_-]", with: "", options: .regularExpression)
        return folded.contains("paidpartnership")
            || folded.contains("partnershiplabel")
            || folded.contains("partnershipdisclosure")
    }

    private static func isPartnershipHelpURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        let host = (components.host ?? "")
            .lowercased()
            .replacingOccurrences(of: "www.", with: "")
        guard host == "help.x.com" || host == "help.twitter.com" else { return false }
        let path = components.path.lowercased()
        return path.contains("paid-partnership") || path.contains("paidpartnership")
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let labels = [
        "paid partnership",
        "付费合作",
        "付费合作伙伴",
        "付费伙伴关系",
        "付費合作",
        "付費合作夥伴",
        "有料パートナーシップ",
        "유료 파트너십",
        "colaboración pagada",
        "asociación pagada",
        "partenariat rémunéré",
        "partenariat payant",
        "bezahlte partnerschaft",
        "parceria paga",
        "colaboração paga",
        "partnership a pagamento"
    ]
}
