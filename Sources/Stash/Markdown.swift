import AppKit

enum Markdown {
    // MARK: - Markdown → styled text

    static func render(_ text: String, size: CGFloat = 13, done: Bool = false) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: size)
        let color: NSColor = done ? .tertiaryLabelColor : .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? NSAttributedString(markdown: text, options: options, baseURL: nil)) ?? NSAttributedString(string: text)
        let out = NSMutableAttributedString(attributedString: parsed)
        let full = NSRange(location: 0, length: out.length)
        out.addAttributes([.font: base, .foregroundColor: color, .paragraphStyle: paragraph], range: full)

        out.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                out.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06),
                ], range: range)
                return
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
                out.addAttribute(.font, value: NSFont(descriptor: descriptor, size: size) ?? base, range: range)
            }
            if intent.contains(.strikethrough) {
                out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }

        out.enumerateAttribute(.link, in: full) { value, range, _ in
            guard value != nil else { return }
            out.removeAttribute(.link, range: range)
            out.addAttributes([
                .foregroundColor: done ? NSColor.tertiaryLabelColor : NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        }

        if done {
            out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: full)
        }
        return out
    }

    // MARK: - Rich clipboard → Markdown

    /// Prefers the HTML or RTF flavour so bold, italic, code and links survive a capture.
    @MainActor
    static func fromPasteboard(_ pasteboard: NSPasteboard) -> String? {
        if let data = pasteboard.data(forType: .html),
           let attributed = NSAttributedString(html: data, documentAttributes: nil) {
            return clean(markdown(from: attributed))
        }
        if let data = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            return clean(markdown(from: attributed))
        }
        return pasteboard.string(forType: .string)
    }

    static func markdown(from attributed: NSAttributedString) -> String {
        var out = ""
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full) { attributes, range, _ in
            let run = (attributed.string as NSString).substring(with: range)
            let font = attributes[.font] as? NSFont
            let link = (attributes[.link] as? URL)?.absoluteString ?? (attributes[.link] as? String)
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let weight = (font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
            let isCode = traits.contains(.monoSpace)
            let isBold = !isCode && (traits.contains(.bold) || weight >= 0.3)
            let isItalic = !isCode && traits.contains(.italic)

            out += run.components(separatedBy: "\n").map { line in
                wrap(line, code: isCode, bold: isBold, italic: isItalic, link: link)
            }
            .joined(separator: "\n")
        }
        return out
    }

    private static func wrap(_ line: String, code: Bool, bold: Bool, italic: Bool, link: String?) -> String {
        let core = line.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return line }
        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        let trailing = String(line.reversed().prefix { $0 == " " || $0 == "\t" })

        var text = core
        if code { text = "`\(text)`" }
        if italic { text = "*\(text)*" }
        if bold { text = "**\(text)**" }
        if let link, !code { text = "[\(text)](\(link))" }
        return leading + text + trailing
    }

    private static func clean(_ markdown: String) -> String {
        var text = markdown
        // HTML lists arrive as "\t•\t" / "\t1.\t" markers; turn them back into Markdown bullets.
        text = text.replacingOccurrences(of: #"(?m)^\t*[•◦▪‣⁃·]\t"#, with: "- ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\t*(\d+)\.\t"#, with: "$1. ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingOccurrences(of: "****", with: "")
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
