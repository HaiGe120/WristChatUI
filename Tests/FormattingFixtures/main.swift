import Foundation

var checks = 0
func check(_ condition: Bool, _ description: String) {
    checks += 1
    precondition(condition, "Formatting fixture failed: \(description)")
}
func rendered(_ text: String) -> String { String(MessageTextFormatting.attributed(text).characters) }

let paragraphs = "First paragraph.\n\nSecond paragraph.\nA separate line."
check(rendered(paragraphs) == paragraphs, "line breaks and blank paragraphs survive")
let bullets = "- **First** item\n- Second item\n\n1. Numbered\n2. Next"
check(rendered(bullets) == "- First item\n- Second item\n\n1. Numbered\n2. Next", "unordered/numbered list boundaries remain visible")
let multilingual = "上海天气\n\n今天多云。\n• 出门带伞\n• 下午再看看\n\n日本語の行\n한국어 줄"
check(rendered(multilingual) == multilingual, "multilingual paragraphs and bullets remain intact")
check(rendered("One\r\n\r\nTwo\rThree") == "One\n\nTwo\nThree", "Windows and old CR line endings normalize to visible breaks")
check(rendered("**Heading**\nA *small* answer with `code`.") == "Heading\nA small answer with code.", "inline Markdown remains styled without losing breaks")
let styled = MessageTextFormatting.attributed("**Bold** and [source](https://example.test/source)\nnext line")
check(styled.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "bold attribute retained")
check(styled.runs.contains { $0.link?.absoluteString == "https://example.test/source" }, "actual clickable source attribute retained")
check(String(styled.characters) == "Bold and source\nnext line", "link text and next line remain readable")
let code = "Before\n\n```swift\nlet value = \"*literal*\"\n  print(value)\n```\nAfter"
check(rendered(code) == "Before\n\nlet value = \"*literal*\"\n  print(value)\nAfter", "fenced code is literal with exact indentation and line breaks")
let codeValue = MessageTextFormatting.attributed("```text\n**not bold** [not a link](https://example.test)\n```")
check(String(codeValue.characters) == "**not bold** [not a link](https://example.test)\n", "Markdown characters inside code never interpreted")
check(codeValue.runs.allSatisfy { $0.link == nil && $0.inlinePresentationIntent == .code }, "fenced code retains code style and no fabricated links")
check(rendered("~~~python\nprint('hello')\n~~~") == "print('hello')\n", "tilde fences handled")
check(rendered("```\na\n``\nb\n```") == "a\n``\nb\n", "short delimiter does not close a longer fence")
check(rendered("Start\n```swift\nlet unfinished = 1") == "Start\nlet unfinished = 1", "streamed unfinished code remains visible")
check(rendered("incomplete **bold") == "incomplete **bold", "unfinished inline Markdown remains readable")
check(rendered("Use three ticks inline: ```example```.") == "Use three ticks inline: example.", "inline triple backticks are not mistaken for a block")
check(rendered("    ```literal\n    **text**\n") == "    ```literal\n    text\n", "deep indentation is not mistaken for a fence")
check(rendered("```\n\n```") == "\n", "empty code line remains a line")
let custom = "Answer in Chinese. Output exact JSON when asked."
let guided = WatchResponseFormatting.applying(toSystemPrompt: custom)
check(guided.hasPrefix(custom + "\n\n"), "custom system prompt preserved byte-for-byte")
check(guided.contains("short paragraphs separated by a blank line"), "Watch guidance asks for readable paragraph boundaries")
check(guided.contains("Preserve necessary detail, exact code, source links"), "guidance does not truncate detail/code/citations")
check(WatchResponseFormatting.applying(toSystemPrompt: guided) == guided, "guidance applies idempotently")
check(WatchResponseFormatting.applying(toSystemPrompt: "   \n") == WatchResponseFormatting.guidance, "blank custom prompt uses guidance directly")
print("Formatting fixtures: \(checks) checks passed")
