import ApelinCore
import Foundation

/// Opening a call shows what it changed. An edit answers with a diff; a
/// write or a create answers with one line counting the file, and what it
/// wrote is the content it was given — without that the row had nothing to
/// open at all.
func checkToolCallSections() {
    func json(_ values: [String: JSONValue]) -> String {
        String(decoding: (try? JSONCoding.encode(JSONValue.object(values))) ?? Data(), as: UTF8.self)
    }
    func call(_ tool: String, _ arguments: [String: JSONValue], result: String?) -> ChatMessage {
        var step = ChatMessage(role: .tool, text: "Edit Sources/Tweak.m")
        step.tool = tool
        let head = json(arguments)
        step.detail = result.map { head + "\n\n" + $0 } ?? head
        return step
    }

    let content = "#import <Foundation/Foundation.h>\n\nint value;\n"
    let arguments: [String: JSONValue] = [
        "reason": .string("Edit Sources/Tweak.m"),
        "path": .string("Sources/Tweak.m"),
        "content": .string(content),
    ]
    let written = ToolCallSections.sections(of: call(
        "file_write", arguments, result: "Replaced Sources/Tweak.m (48 bytes, +2 -0)",
    ))
    precondition(written == [.init(name: "Tweak.m", value: content, isResult: true)],
                 "a write opens as the content it was given: \(written)")
    precondition(
        ToolCallSections.sections(of: call(
            "file_create", arguments, result: "Created Sources/Tweak.m (48 bytes, +3 -0)",
        )) == written,
        "a create opens the same way",
    )
    precondition(
        ToolCallSections.sections(of: call(
            "write_file", arguments, result: "Replaced Sources/Tweak.m (48 bytes, +2 -0)",
        )) == written,
        "a call recorded under an earlier name opens the same way",
    )

    let patch: [String: JSONValue] = [
        "path": .string("Sources/Tweak.m"),
        "old_text": .string("int value;"),
        "new_text": .string("int other;"),
    ]
    let diff = "--- a/Sources/Tweak.m\n+++ b/Sources/Tweak.m\n@@ -1,1 +1,1 @@\n-int value;\n+int other;"
    let edited = ToolCallSections.sections(of: call(
        "file_edit", patch, result: "Patched Sources/Tweak.m (1 replacement, +1 -1)\n" + diff,
    ))
    precondition(edited == [.init(name: "Tweak.m", value: diff, isResult: true)],
                 "an edit opens as its diff, not as its arguments: \(edited)")
    precondition(edited.first?.kind == .diff, "and reads as one")

    var bare = call("file_edit", patch, result: "Patched Sources/Tweak.m (1 replacement, +0 -0)")
    precondition(ToolCallSections.sections(of: bare).isEmpty, "a patch without a diff adds nothing")
    bare = call("file_write", ["path": .string("Sources/Empty.m")], result: "Created Sources/Empty.m (0 bytes, +0 -0)")
    precondition(ToolCallSections.sections(of: bare).isEmpty, "neither does a write with no content")

    // A read shows the file, not the line numbers the tool put in front of it.
    let read = ToolCallSections.sections(of: call(
        "file_read", ["path": .string("Sources/Tweak.m")], result: "1\tint value;\n2\t",
    ))
    precondition(read == [.init(name: "Tweak.m", value: "int value;\n", isResult: true)],
                 "a read opens as the file: \(read)")

    // Everything else shows its arguments and its result, and never the
    // reason, which the line above already says.
    let shell = call(
        "shell_run",
        ["reason": .string("Check the toolchain"), "argv": .array([.string("clang"), .string("-v")])],
        result: "clang version 15.0.0",
    )
    precondition(ToolCallSections.sections(of: shell).map(\.name) == ["argv", "Result"],
                 "a command shows what it ran and what it answered")

    var unknown = ChatMessage(role: .tool, text: "Look it up")
    unknown.tool = "mcp_search"
    unknown.detail = json(["reason": .string("Find it"), "query": .string("apelin")])
    precondition(ToolCallSections.sections(of: unknown).map(\.name) == ["query"],
                 "a tool this build does not know shows its arguments")

    print("ok: a file edit opens as its diff, a write or a create as the content it was given")
}
