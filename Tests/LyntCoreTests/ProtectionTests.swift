import XCTest
@testable import LyntCore

final class ProtectionTests: XCTestCase {
    struct Fixture: Decodable { let id: String; let input: String; let forbidden: [String]; let zeroSegments: Bool }
    let engine = ProtectionEngine()

    func testSharedPrivacyCorpusAndIdentityRoundTrip() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "protection-corpus", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            let prepared = engine.prepare(fixture.input)
            let request = prepared.request(options: .init())
            let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            for forbidden in fixture.forbidden {
                XCTAssertFalse(request.segments.contains { $0.text.contains(forbidden) }, "\(fixture.id): leaked \(forbidden)")
            }
            XCTAssertEqual(prepared.segments.isEmpty, fixture.zeroSegments, "\(fixture.id): \(payload)")
            XCTAssertEqual(try TextRecomposer().recompose(document: prepared, suggestions: [], acceptedIDs: []), fixture.input, fixture.id)
            for segment in prepared.segments {
                XCTAssertEqual(segment.range.substring(in: fixture.input), segment.text, fixture.id)
                XCTAssertFalse(prepared.protectedSpans.contains { $0.range.overlaps(segment.range) }, fixture.id)
            }
        }
    }

    func testFencedTechnicalLanguagesNeverLeaveMachine() throws {
        let snippets: [(String, String)] = [
            ("go", "func main() { fmt.Println(\"private\") }"),
            ("python", "def main():\n    print('private')"),
            ("java", "public class Main { String value = \"private\"; }"),
            ("typescript", "const fn = (id: string): void => console.log(id);"),
            ("javascript", "function run() { return `private ${token}`; }"),
            ("csharp", "public string Run() => \"private\";"),
            ("cpp", "std::vector<int> values = {1, 2};"),
            ("c", "int main(void) { return 0; }"),
            ("bash", "curl -H 'Authorization: Bearer private' https://example.test"),
            ("html", "<input value=\"private\" />"),
            ("xml", "<root key=\"private\"><child /></root>"),
            ("dart", "Widget build(BuildContext context) => Text('private');"),
            ("css", ".private { color: #112233; }"),
            ("kotlin", "fun main() { val token = \"private\" }"),
            ("rust", "fn main() { let token = \"private\"; }"),
            ("sql", "SELECT token FROM credentials WHERE id = 1;"),
            ("yaml", "credentials:\n  token: private"),
            ("toml", "[credentials]\ntoken = 'private'"),
            ("", "thisLooksLikeCode(private_token)")
        ]
        for (language, snippet) in snippets {
            let fence = "```\(language)\r\n\(snippet)\r\n```\r\n"
            let input = "He don't knows the answer.\r\n\(fence)Can you explain why this happen?"
            let prepared = engine.prepare(input)
            XCTAssertEqual(prepared.segments.map(\.text), ["He don't knows the answer.", "Can you explain why this happen?"], language)
            XCTAssertTrue(prepared.protectedSpans.contains { $0.range.substring(in: input)?.contains(fence) == true }, language)
            let response = WritingReviewResponse(segments: prepared.segments.map {
                .init(id: $0.id, suggestions: $0.id == "s1" ? [.init(category: .correctness, source: "don't knows", replacement: "doesn't know", explanation: "Subject–verb agreement.")] : [])
            })
            let validated = try SuggestionValidator().validate(response, document: prepared, options: .init())
            let output = try TextRecomposer().recompose(document: prepared, suggestions: validated.suggestions, acceptedIDs: Set(validated.suggestions.map(\.id)))
            XCTAssertEqual(output, input.replacingOccurrences(of: "don't knows", with: "doesn't know"), language)
            XCTAssertTrue(output.contains(fence), language)
        }
    }

    func testUnfencedCodeOnlyProducesZeroSegments() {
        let snippets = [
            "func run() {\n    return 42\n}",
            "def run():\n    return 'private'",
            "public class Main {\n    private String token = \"private\";\n}",
            "const getUser = (id: string) => fetch(`/api/users/${id}`);",
            "function run() {\n  return \"private\";\n}",
            "using System;\npublic class Main {\n  public string Run() => \"private\";\n}",
            "#include <stdio.h>\nint main(void) {\n  printf(\"private\");\n  return 0;\n}",
            "curl -X POST https://example.test -H 'Authorization: Bearer private'",
            "<root>\n  <item key=\"private\">value</item>\n</root>",
            ".private {\n  color: red;\n}",
            "Widget build(BuildContext context) {\n  return Text('private');\n}",
            "fn main() {\n  let secret = \"private\";\n}",
            "SELECT id, token\nFROM users\nWHERE id = 42;",
            "server:\n  host: example.test\n  token: private",
            "[server]\nhost = 'example.test'\nport = 8080"
        ]
        for snippet in snippets { XCTAssertTrue(engine.prepare(snippet).segments.isEmpty, "Leaked: \(engine.prepare(snippet).segments.map(\.text)) from \(snippet)") }
    }

    func testExplicitOverrideNeverBypassesProtection() {
        let options = ReviewOptions(contextKind: .search, forceEnglish: true)
        let prepared = engine.prepare("fix error site:example.test /api/private sk-SECRET1234567890", options: options)
        XCTAssertEqual(prepared.segments.map(\.text), ["fix error"])
        XCTAssertEqual(prepared.request(options: options).enabledCategories, [.correctness])
        XCTAssertFalse(prepared.request(options: options).tone.detect)
        XCTAssertTrue(engine.prepare("Bu xəta niyə baş verir?", options: options).segments.isEmpty)
    }

    func testLocalLanguageSignalsOnRealNaturalLanguageFramework() {
        let gate = LanguageGate()
        XCTAssertEqual(gate.classify("He don't knows the answer."), .english)
        XCTAssertEqual(gate.classify("Can you fix it?"), .english)
        XCTAssertEqual(gate.classify("We've completed the review and I've saved the changes."), .english)
        XCTAssertEqual(gate.classify("Bu hatayı nasıl düzeltebilirim?"), .nonEnglish)
        XCTAssertEqual(gate.classify("Bu xəta niyə baş verir?"), .nonEnglish)
        XCTAssertEqual(gate.classify("fix error"), .ambiguous)
        XCTAssertEqual(gate.classify("fix error", forceEnglish: true), .english)
        XCTAssertEqual(gate.classify(""), .ambiguous)
    }

    func testDeterministicPayloadMatchesPortableContract() throws {
        let document = engine.prepare("He don't knows the answer.")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = String(decoding: try encoder.encode(document.request(options: .init())), as: UTF8.self)
        XCTAssertEqual(payload, #"{"contextKind":"prompt","enabledCategories":["correctness","clarity","engagement","delivery"],"segments":[{"id":"s1","text":"He don't knows the answer."}],"task":"review_english_prose","tone":{"detect":true,"target":"preserve"}}"#)
    }

    func testUnicodeCRLFAndSeededIdentityCorpus() throws {
        let tokens = ["🙂", "👩🏽‍💻", "e\u{301}", "\r\n", "\n", "\t", "你好", "Bu xəta", "`foo_bar`", "/api/v1/private", "", " ", "\u{200D}"]
        var seed: UInt64 = 104729
        for _ in 0..<120 {
            var input = "He don't knows the answer."
            for _ in 0..<15 { seed = seed &* 6364136223846793005 &+ 1; input += tokens[Int(seed % UInt64(tokens.count))] }
            let prepared = engine.prepare(input)
            XCTAssertEqual(try TextRecomposer().recompose(document: prepared, suggestions: [], acceptedIDs: []), input)
            for segment in prepared.segments { XCTAssertEqual(segment.range.substring(in: input), segment.text) }
        }
    }

    func testNaturalEnglishInsideTechnicalBlocksIsNeverEligible() {
        let question = "Can you explain why this happen?"
        let bodies = [
            "# This is a private unmarked shell or Python comment.\n",
            "java.lang.RuntimeException: This is a private error message.\nThis is a continuation of the private error message.\n    at com.example.Main.run(Main.java:12)\n\n",
            "/*\nThis is a private multiline code comment.\n*/\n",
            "<!--\nThis is a private markup comment.\n-->\n",
            "const template = `\nThis is a private multiline string.\n`;\n",
            "def run():\n    \"\"\"\nThis is a private multiline docstring.\n    \"\"\"\n",
            "description: |\n  This is a private YAML block scalar.\n  This must never leave the machine.\n",
            "func run() {\nThis is ambiguous natural English inside code braces.\n}\n"
        ]
        for body in bodies {
            let prepared = engine.prepare(body + question)
            XCTAssertEqual(prepared.segments.map(\.text), [question], body)
        }
        let http = "HTTP/1.1 200 OK\nContent-Type: text/plain\n\nThis is a private response body.\nCan you interpret this response?"
        XCTAssertTrue(engine.prepare(http).segments.isEmpty)
    }

    func testContractionsAndUnclosedQuotesStayBounded() {
        let input = "I don't know why this problem doesn't stop. " + String(repeating: "The request should preserve its original meaning. ", count: 200)
        XCTAssertFalse(engine.prepare(input).segments.isEmpty)
    }

    func testIndependentPrivacyAuditRegressions() {
        let question = "Can you explain the issue?"
        let structures = [
            "<div>\nThis is private text inside a markup element.\n</div>\n",
            "Please inspect <div>This is private text inside a markup element.</div>.\n",
            "<root><item>This is private nested XML text.</item></root>\n",
            "cat <<EOF\nThis is a private shell heredoc body.\nEOF\n",
            "cat <<-'END'\nThis is a private tab stripped shell body.\n\tEND\n",
            "SELECT description\nFROM messages\nWHERE description =\n'This is a private multiline SQL value\nthat should never leave the machine';\n",
            "let text = \"This is a private multiline escaped string\\\nthat should never leave the machine\";\n"
        ]
        for body in structures {
            let document = engine.prepare(body + question)
            XCTAssertEqual(document.segments.map(\.text), [question], body)
        }
        for cue in ["passphrase", "credential", "credentials", "cookie", "refresh token", "access token", "token", "passcode"] {
            let input = "My \(cue) is open sesame private access phrase and I need help with this request.\n\(question)"
            let document = engine.prepare(input)
            XCTAssertEqual(document.segments.map(\.text), [question], cue)
        }
        for command in ["Please execute echo this is private shell argument content and tell me the result.", "Run this command: printf hello world", "Please inspect $(echo this is a private shell command).", "Please do the work && echo this is a private command."] {
            XCTAssertEqual(engine.prepare(command + "\n" + question).segments.map(\.text), [question], command)
        }
        for malformed in ["<div>\nThis is a private unclosed markup body.\n", "cat <<EOF\nThis is a private unterminated heredoc.\n", "'This is a private unterminated SQL value\n"] {
            XCTAssertTrue(engine.prepare(malformed + question).segments.isEmpty, malformed)
        }
        XCTAssertEqual(engine.prepare("He don't knows the answer.").segments.map(\.text), ["He don't knows the answer."])
    }
}
