import Foundation

/// Ordered block scanning, structural balancing, lexical detectors, then interval merging.
/// Deliberately trades missed review opportunities for local preservation of ambiguous content.
public struct ProtectionEngine: Sendable {
    public init() {}

    public func prepare(_ text: String, options: ReviewOptions = .init()) -> PreparedDocument {
        guard !text.isEmpty else { return .init(original: text, protectedSpans: [], segments: []) }
        let spans = protectedSpans(in: text)
        let original = text as NSString
        var segments: [TextSegment] = []
        var skipped = spans.map { SkippedRegion(range: $0.range, reason: $0.reasons.map(\.rawValue).sorted().joined(separator: ", ")) }
        let gate = LanguageGate()
        var cursor = 0
        let boundaries = spans.map(\.range) + [UTF16Range(location: original.length, length: 0)]
        for boundary in boundaries {
            if cursor < boundary.location {
                let candidate = NSRange(location: cursor, length: boundary.location - cursor)
                // Split at sentence/newline boundaries before language detection, allowing separate
                // English and Turkish sentences in the same paragraph to remain independent.
                let body = original.substring(with: candidate) as NSString
                let pattern = #"[^\r\n.!?]+(?:[.!?]+|$)"#
                let matches = Self.matches(pattern, in: body as String)
                for match in matches {
                    let raw = body.substring(with: match.range)
                    let leftTrim = (raw as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
                    guard leftTrim.location != NSNotFound else { continue }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    let range = UTF16Range(location: cursor + match.range.location + leftTrim.location, length: trimmed.utf16.count)
                    switch gate.classify(trimmed, forceEnglish: options.forceEnglish) {
                    case .english:
                        segments.append(.init(id: "s\(segments.count + 1)", text: trimmed, range: range))
                    case .nonEnglish:
                        skipped.append(.init(range: range, reason: "Non-English prose preserved locally"))
                    case .ambiguous:
                        skipped.append(.init(range: range, reason: "Ambiguous or short prose; Review as English is available"))
                    }
                }
            }
            cursor = max(cursor, boundary.upperBound)
        }
        return .init(original: text, protectedSpans: spans, segments: segments, skipped: skipped)
    }

    public func protectedSpans(in text: String) -> [ProtectedSpan] {
        let source = text as NSString
        let lines = Self.lines(in: text)
        var found: [ProtectedSpan] = []
        func add(_ range: NSRange, _ reason: ProtectionReason) {
            guard range.length > 0, range.location >= 0, range.location <= source.length,
                  range.length <= source.length - range.location else { return }
            found.append(.init(range: .init(location: range.location, length: range.length), reasons: [reason]))
        }
        let explicitFences = Self.fencedRanges(lines, sourceLength: source.length)
        for range in explicitFences { add(range, .codeBlock) }
        func fenceContaining(_ offset: Int) -> NSRange? {
            explicitFences.first { $0.location <= offset && offset < $0.location + $0.length }
        }
        func openingOutsideFences(_ literal: String, from start: Int) -> NSRange? {
            var cursor = start
            while cursor < source.length {
                let match = source.range(of: literal, options: [.literal], range: NSRange(location: cursor, length: source.length - cursor))
                if match.location == NSNotFound { return nil }
                if let fence = fenceContaining(match.location) { cursor = fence.location + fence.length }
                else { return match }
            }
            return nil
        }
        // This pass is independent of line consumption: a Python body or a fenced code block
        // may contain the opening delimiter on a line that another scanner skips.
        var literalCursor = 0
        let literalPairs = [("/*", "*/"), ("<!--", "-->"), ("\"\"\"", "\"\"\""), ("'''", "'''")]
        while literalCursor < source.length {
            let candidates = literalPairs.compactMap { opening, closing -> (NSRange, String)? in
                openingOutsideFences(opening, from: literalCursor).map { ($0, closing) }
            }
            guard let (opening, closer) = candidates.min(by: { $0.0.location < $1.0.location }) else { break }
            let searchStart = opening.location + opening.length
            let closing = source.range(of: closer, options: [.literal], range: NSRange(location: searchStart, length: source.length - searchStart))
            let end = closing.location == NSNotFound ? source.length : closing.location + closing.length
            add(NSRange(location: opening.location, length: end - opening.location), .codeBlock)
            literalCursor = end
        }
        // Balanced XML/HTML elements own their text nodes, even when they contain fluent prose.
        // An unmatched opening tag is ambiguous and protects the remainder of the input.
        var tagStack: [(name: String, start: Int)] = []
        let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
        for tag in Self.matches(#"</?([A-Za-z][A-Za-z0-9:._-]*)(?:\s[^<>]*?)?\s*/?>"#, in: text) {
            if fenceContaining(tag.range.location) != nil { continue }
            let raw = source.substring(with: tag.range)
            let name = source.substring(with: tag.range(at: 1)).lowercased()
            if raw.hasPrefix("</") {
                if let matching = tagStack.lastIndex(where: { $0.name == name }) {
                    let start = tagStack[matching].start
                    add(NSRange(location: start, length: tag.range.location + tag.range.length - start), .structuredData)
                    tagStack.removeSubrange(matching...)
                } else { add(tag.range, .markup) }
            } else if raw.hasSuffix("/>") || voidTags.contains(name) {
                add(tag.range, .markup)
            } else { tagStack.append((name, tag.range.location)) }
        }
        if let opening = tagStack.first { add(NSRange(location: opening.start, length: source.length - opening.start), .ambiguous) }
        for declaration in Self.matches(#"<[!?][^>]*>"#, in: text) { add(declaration.range, .markup) }

        // Quoted strings are parsed across line boundaries, with escapes and SQL doubled quotes.
        // A contraction/possessive apostrophe inside a word is not an opening string delimiter.
        var quoteCursor = 0
        while quoteCursor < source.length {
            if let fence = fenceContaining(quoteCursor) { quoteCursor = fence.location + fence.length; continue }
            let quote = source.character(at: quoteCursor)
            guard quote == 34 || quote == 39 else { quoteCursor += 1; continue }
            if quote == 39, quoteCursor > 0,
               Self.isWordUnit(source.character(at: quoteCursor - 1)) { quoteCursor += 1; continue }
            let start = quoteCursor
            quoteCursor += 1
            var closed = false
            while quoteCursor < source.length {
                let current = source.character(at: quoteCursor)
                if current == 92 { quoteCursor = min(source.length, quoteCursor + 2); continue }
                if current == quote {
                    if quote == 39, quoteCursor + 1 < source.length, source.character(at: quoteCursor + 1) == 39 {
                        quoteCursor += 2; continue
                    }
                    if quote == 39, quoteCursor > 0, quoteCursor + 1 < source.length,
                       Self.isWordUnit(source.character(at: quoteCursor - 1)), Self.isWordUnit(source.character(at: quoteCursor + 1)) {
                        quoteCursor += 1; continue
                    }
                    quoteCursor += 1; closed = true; break
                }
                quoteCursor += 1
            }
            add(NSRange(location: start, length: quoteCursor - start), closed ? .technicalToken : .ambiguous)
        }
        // Shell heredoc bodies are arbitrary data, not prose; quoted/tab-stripped delimiters work
        // without exposing the body. Unknown or missing delimiters fail closed through EOF.
        for (lineIndex, line) in lines.enumerated() where line.body.contains("<<") {
            if fenceContaining(line.range.location) != nil { continue }
            let markers = Self.matches(#"<<(-)?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?"#, in: line.body)
            if markers.isEmpty { add(NSRange(location: line.range.location, length: source.length - line.range.location), .ambiguous) }
            for marker in markers {
                let markerText = (line.body as NSString).substring(with: marker.range(at: 2))
                let tabsAllowed = marker.range(at: 1).location != NSNotFound
                var ending: Int?
                for candidate in lines.dropFirst(lineIndex + 1) {
                    let body = tabsAllowed ? String(candidate.body.drop(while: { $0 == "\t" })) : candidate.body
                    if body == markerText { ending = candidate.range.location + candidate.range.length; break }
                }
                let end = ending ?? source.length
                add(NSRange(location: line.range.location, length: end - line.range.location), .codeBlock)
            }
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.body.trimmingCharacters(in: .whitespaces)
            // Explicit Markdown fences are parsed first, including an unterminated fence.
            if let fence = Self.fence(trimmed) {
                var end = index + 1
                while end < lines.count {
                    let closing = lines[end].body.trimmingCharacters(in: .whitespaces)
                    if let candidate = Self.fence(closing), candidate.marker == fence.marker,
                       candidate.count >= fence.count,
                       closing.allSatisfy({ $0 == fence.marker || $0.isWhitespace }) { end += 1; break }
                    end += 1
                }
                let endOffset = end < lines.count ? lines[end].range.location : source.length
                add(NSRange(location: line.range.location, length: endOffset - line.range.location), .codeBlock)
                index = end; continue
            }
            // JSON uses a string-aware balanced scanner; malformed structured blocks are retained
            // conservatively until the next blank line rather than exposing their values.
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                if let endOffset = Self.balancedStructureEnd(source, start: line.range.location),
                   let data = source.substring(with: NSRange(location: line.range.location, length: endOffset - line.range.location)).data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                    add(NSRange(location: line.range.location, length: endOffset - line.range.location), .structuredData)
                    while index < lines.count, lines[index].range.location < endOffset { index += 1 }
                    continue
                }
                // A one-line Markdown link is handled by inline parsing below.
                if !Self.has(#"^\[[^\]]+\]\("#, trimmed) {
                    var end = index + 1
                    while end < lines.count, !lines[end].body.trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
                    let offset = end < lines.count ? lines[end].range.location : source.length
                    add(NSRange(location: line.range.location, length: offset - line.range.location), .structuredData)
                    index = end; continue
                }
            }
            // HTTP traffic, including blank header/body separators, remains a single local block.
            if Self.has(#"^(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|CONNECT|TRACE)\s+\S+\s+HTTP/|^HTTP/\d"#, trimmed) {
                // A body can itself contain natural English, so do not infer its end from language.
                add(NSRange(location: line.range.location, length: source.length - line.range.location), .structuredData)
                index = lines.count; continue
            }
            if line.body.hasPrefix("    ") || line.body.hasPrefix("\t") {
                add(line.range, .codeBlock)
            } else if Self.isLogLine(trimmed) {
                var end = index + 1
                while end < lines.count {
                    let next = lines[end].body.trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || (Self.isClearlyProse(next) && next.hasSuffix("?") && !Self.isTechnicalLine(next) && !lines[end].body.hasPrefix(" ")) { break }
                    end += 1
                }
                let offset = end < lines.count ? lines[end].range.location : source.length
                add(NSRange(location: line.range.location, length: offset - line.range.location), .log)
                index = end; continue
            } else if trimmed.hasPrefix("#") {
                // An unmarked Python/shell comment is indistinguishable from a Markdown heading.
                add(line.range, .ambiguous)
            } else if Self.isTechnicalLine(trimmed) {
                add(line.range, .structuredData)
                if let open = line.body.firstIndex(of: "{") {
                    let start = line.range.location + line.body[..<open].utf16.count
                    let endOffset = Self.codeBlockEnd(source, start: start) ?? source.length
                    add(NSRange(location: line.range.location, length: endOffset - line.range.location), .codeBlock)
                    while index < lines.count, lines[index].range.location < endOffset { index += 1 }
                    continue
                }
                // YAML block scalars and Python bodies may contain natural English; keep their
                // indented continuation together with the structural opening line.
                let indentation = line.body.prefix(while: { $0 == " " || $0 == "\t" }).count
                var end = index + 1
                while end < lines.count {
                    let next = lines[end].body
                    let depth = next.prefix(while: { $0 == " " || $0 == "\t" }).count
                    if next.trimmingCharacters(in: .whitespaces).isEmpty { end += 1; continue }
                    if depth <= indentation { break }
                    end += 1
                }
                if end > index + 1 {
                    let offset = end < lines.count ? lines[end].range.location : source.length
                    add(NSRange(location: line.range.location, length: offset - line.range.location), .structuredData)
                    index = end; continue
                }
            }
            index += 1
        }
        // Inline technical islands. Every regex match is recorded against the untouched original.
        let rules: [(String, ProtectionReason)] = [
            (#"`+[^`\r\n]*`+|`[^\r\n]*$"#, .markup),
            (#"(?m)^(?:\s{0,3}#{1,6}\s+|\s*[-*+]\s+|\s*>\s*|\s*\d+\.\s+)"#, .markup),
            (#"!?\[|\]\([^\r\n)]*\)|\*\*|__|(?<!\w)[*_](?!\s)|(?<=\S)[*_](?!\w)"#, .markup),
            (#"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>\"')]+|\bwww\.[^\s<>\"')]+"#, .technicalToken),
            (#"(?<![\w])(?:~?/|\.{1,2}/)[A-Za-z0-9_@%+.,:=/?&#~$!\[\]{}*;\\-]+|\b[A-Za-z]:\\[^\s]+"#, .technicalToken),
            (#"(?i)(?<!\w)(?:site|filetype|inurl|intitle|after|before):[^\s]+|(?<!\w)-[A-Za-z][\w.-]*|(?<!\w)--[A-Za-z][\w=-]*"#, .searchOperator),
            (#"\"[^\"\r\n]*\"|‘[^’\r\n]*’|“[^”\r\n]*”|(?<![A-Za-z])'[^'\r\n]{1,512}'"#, .technicalToken),
            (#"\b[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+\b|\b[A-Za-z_][A-Za-z0-9_]*::[A-Za-z0-9_:]+|\b\w+[a-z][A-Z]\w*\b|\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+\b|\b[A-Za-z_]\w*\([^\r\n)]*\)"#, .technicalToken),
            (#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b|\b(?:[0-9a-fA-F]{8}-){1}[0-9a-fA-F-]{27,}\b|\b[0-9a-fA-F]{16,}\b"#, .technicalToken),
            (#"(?i)\b(?:go|golang|python|java|javascript|typescript|swift|kotlin|rust|dart|flutter|bash|shell|ruby|php|sql|graphql|jsonl?|yaml|toml|xml|html|css|protobuf|terraform|dockerfile|gradle|npm|pnpm|yarn|pip|git|curl|http|https|c\+\+|c#)\b(?:[ \t]+\d+(?:\.\d+)*)?"#, .technicalToken),
            (#"\b\d+(?:[.:/-]\d+)*\b|\b[0-9]+[A-Za-z][A-Za-z0-9]*\b"#, .number),
            (#"\x1B\[[0-?]*[ -/]*[@-~]"#, .technicalToken),
            (#"(?i)\b(?:sk|pk|ghp|github_pat|glpat|xox[baprs]|AKIA)[-_][A-Za-z0-9_./+=-]{8,}|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?"#, .secret),
            (#"(?i)\b(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|passwd|passphrase|passcode|secret|token|authorization|cookie|credential|connection[_ -]?string)\b\s*(?:is\s+|[:=]\s*|\s+)(?:Bearer\s+)?(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#, .secret),
            (#"\b(?=[A-Za-z0-9_+/=-]{24,}\b)(?=[A-Za-z0-9_+/=-]*[a-z])(?=[A-Za-z0-9_+/=-]*[A-Z0-9])[A-Za-z0-9_+/=-]{24,}\b"#, .secret)
        ]
        for (pattern, reason) in rules {
            for match in Self.matches(pattern, in: text) { add(match.range, reason) }
        }
        // Backtick literals can span lines; an unmatched opening literal protects the remainder.
        var tickCursor = 0
        while tickCursor < source.length {
            let opening = source.range(of: "`", range: NSRange(location: tickCursor, length: source.length - tickCursor))
            if opening.location == NSNotFound { break }
            var runEnd = opening.location + 1
            while runEnd < source.length, source.character(at: runEnd) == 96 { runEnd += 1 }
            let marker = source.substring(with: NSRange(location: opening.location, length: runEnd - opening.location))
            let closing = source.range(of: marker, options: [.literal], range: NSRange(location: runEnd, length: source.length - runEnd))
            let end = closing.location == NSNotFound ? source.length : closing.location + closing.length
            add(NSRange(location: opening.location, length: end - opening.location), .markup)
            tickCursor = end
        }
        // Credential cues that cannot be isolated reliably fail closed for their entire line.
        for line in lines where Self.has(#"(?i)\b(?:private key|BEGIN .*PRIVATE KEY|bearer|password|passwd|passphrase|passcode|api[_ -]?key|secret|authorization|(?:access|refresh)[_ -]?token|token|(?:set[_ -]?)?cookie|credentials?|connection[_ -]?string)\b"#, line.body) {
            add(line.range, .secret)
        }
        for line in lines where Self.has(#"(?i)\b(?:run|execute)\s+(?:(?:this|the)\s+)?(?:command\s*:\s*)?(?:echo|printf|curl|wget|bash|sh|zsh|git|npm|pnpm|yarn|python\d?|node|docker|kubectl|sudo|cat|grep|rg|sed|awk|chmod|rm|cp|mv)\b|\b(?:run|execute)\s+(?:this|the)\s+command\s*[:=]|\$\(|\$\{|&&|\|\|"#, line.body) {
            add(line.range, .ambiguous)
        }
        return Self.merge(found)
    }

    private struct Line { let range: NSRange; let body: String }
    private static func lines(in text: String) -> [Line] {
        let source = text as NSString
        var result: [Line] = []
        var position = 0
        while position < source.length {
            var start = 0, end = 0, contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
            result.append(.init(range: NSRange(location: start, length: end - start), body: source.substring(with: NSRange(location: start, length: contentsEnd - start))))
            position = end
        }
        return result
    }
    private static func fence(_ line: String) -> (marker: Character, count: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix(while: { $0 == first }).count
        return count >= 3 ? (first, count) : nil
    }
    private static func fencedRanges(_ lines: [Line], sourceLength: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = 0
        while index < lines.count {
            guard let opening = fence(lines[index].body.trimmingCharacters(in: .whitespaces)) else { index += 1; continue }
            let start = lines[index].range.location
            var end = index + 1
            while end < lines.count {
                let body = lines[end].body.trimmingCharacters(in: .whitespaces)
                if let closing = fence(body), closing.marker == opening.marker, closing.count >= opening.count,
                   body.allSatisfy({ $0 == opening.marker || $0.isWhitespace }) { end += 1; break }
                end += 1
            }
            let offset = end < lines.count ? lines[end].range.location : sourceLength
            ranges.append(NSRange(location: start, length: offset - start))
            index = end
        }
        return ranges
    }
    private static func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == 95
    }
    private static func balancedStructureEnd(_ source: NSString, start: Int) -> Int? {
        var stack: [unichar] = []
        var inString = false, escaped = false, started = false
        for index in start..<source.length {
            let ch = source.character(at: index)
            if inString {
                if escaped { escaped = false }
                else if ch == 92 { escaped = true }
                else if ch == 34 { inString = false }
                continue
            }
            if ch == 34 { inString = true; continue }
            if ch == 123 || ch == 91 { stack.append(ch); started = true }
            if ch == 125 || ch == 93 {
                guard let open = stack.popLast(), (open == 123 && ch == 125) || (open == 91 && ch == 93) else { return nil }
                if stack.isEmpty, started { return index + 1 }
            }
        }
        return nil
    }
    private static func codeBlockEnd(_ source: NSString, start: Int) -> Int? {
        var depth = 0
        var quote: unichar? = nil
        var escaped = false
        for index in start..<source.length {
            let ch = source.character(at: index)
            if let current = quote {
                if escaped { escaped = false }
                else if ch == 92 { escaped = true }
                else if ch == current { quote = nil }
                continue
            }
            if ch == 34 || ch == 39 || ch == 96 { quote = ch; continue }
            if ch == 123 { depth += 1 }
            if ch == 125 { depth -= 1; if depth == 0 { return index + 1 } }
        }
        return nil
    }
    private static func isClearlyProse(_ line: String) -> Bool {
        has(#"(?i)^(?:why|how|can|could|would|please|this|that|the|i |we |it |he |she |they |what|when|is |does |do |should|explain|help)\b"#, line)
    }
    private static func isLogLine(_ line: String) -> Bool {
        has(#"(?i)^(?:Traceback\b|File \"|at\s+\S+\(|(?:[\w$]+\.)*[\w$]*(?:Error|Exception)(?::|\b)|Caused by:|\[?(?:DEBUG|INFO|WARN|ERROR|FATAL|TRACE)\]?\s|\d{4}-\d\d-\d\d[T ]|\[\d\d:|\$\s|>>>\s)"#, line)
    }
    private static func isTechnicalLine(_ line: String) -> Bool {
        if line.isEmpty { return false }
        let patterns = [
            #"^(?:[{}\[\]();]+[,;]?|```.*|~~~.*)$"#,
            #"(?i)^(?:import|from\s+\S+\s+import|package|func|def|class|interface|enum|struct|extension|protocol|namespace|using|public|private|protected|internal|export|const|let|var|val|fn|use|impl|trait|typedef|template|#include|#define|#!|@\w+)\b"#,
            #"(?i)^(?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|FROM|WHERE|JOIN|ORDER BY|GROUP BY|mutation|query|syntax\s*=|message\s+\w+\s*\{|resource\s+\"|provider\s+\"|FROM\s+\S+|RUN\s|COPY\s|WORKDIR\s|CMD\s|ENTRYPOINT\s)\b"#,
            #"^(?://|/\*|\* |\*/|<!--|-->|<[/!?]?[A-Za-z][^>]*>|---$|\+\+\+\s|@@\s|diff --git|index [0-9a-f]|[+-](?:\s|[a-zA-Z{]))"#,
            #"(?i)^(?:curl|wget|git|npm|pnpm|yarn|pip\d?|python\d?|node|docker|kubectl|go\s+(?:run|build|test)|javac|gradle|mvn|cargo|sudo|echo|printf|cd|ls|cat|grep|rg|chmod|rm|cp|mv|bash|sh|zsh|set\s+-)\s|^java\s+(?:-|[A-Z]|[\w.-]+\.jar)"#,
            #"^[A-Za-z_][\w.\[\]-]*\s*(?:=|:=|=>|\+=|-=)\s*\S"#,
            #"^[\w.-]+\s*:\s*(?:\S|$)|^[-]\s+[\w.-]+\s*:\s*\S|^\[[\w.-]+\]$"#,
            #"^(?:[A-Za-z_$][\w.$]*\s*\(|return\s+.*[;{}]|if\s*\(|for\s*\(|while\s*\(|try\s*\{|catch\s*\(|else\s*\{|[.#][\w-]+.*\{|[a-z][\w-]*\s*\{)"#,
            #"^[A-Za-z_]\w*(?:<[^>]+>)?\s+[A-Za-z_]\w*\s*(?:\(|=|;)"#
        ]
        return patterns.contains { has($0, line) }
    }
    private static func has(_ pattern: String, _ text: String) -> Bool { !matches(pattern, in: text).isEmpty }
    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
    }
    private static func merge(_ spans: [ProtectedSpan]) -> [ProtectedSpan] {
        var result: [ProtectedSpan] = []
        for span in spans.sorted(by: { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }) {
            if var last = result.last, span.range.location <= last.range.upperBound {
                result.removeLast()
                last.range.length = max(last.range.upperBound, span.range.upperBound) - last.range.location
                last.reasons.formUnion(span.reasons)
                result.append(last)
            } else { result.append(span) }
        }
        return result
    }
}
