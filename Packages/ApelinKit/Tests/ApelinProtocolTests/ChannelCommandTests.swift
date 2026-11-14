import ApelinProtocol
import Foundation
import XCTest

/// What a WeChat message asks of the channel itself (2026-11-15).
final class ChannelCommandTests: XCTestCase {
    func testTheCommandsRead() {
        XCTAssertEqual(ChannelCommands.parse("/sessions"), .sessions)
        XCTAssertEqual(ChannelCommands.parse("/ls"), .sessions)
        XCTAssertEqual(ChannelCommands.parse("/use 2"), .use("2"))
        XCTAssertEqual(ChannelCommands.parse("/use 新"), .use("新"))
        XCTAssertEqual(ChannelCommands.parse("/current"), .current)
        XCTAssertEqual(ChannelCommands.parse("/workspace"), .workspace(nil))
        XCTAssertEqual(ChannelCommands.parse("/workspace 3"), .workspace("3"))
        XCTAssertEqual(ChannelCommands.parse("/model"), .model(nil, nil))
        XCTAssertEqual(ChannelCommands.parse("/model 5 hi"), .model("5", "hi"))
        XCTAssertEqual(ChannelCommands.parse("/effort"), .effort(nil))
        XCTAssertEqual(ChannelCommands.parse("/effort mid"), .effort("mid"))
        XCTAssertEqual(ChannelCommands.parse("/help"), .help)
    }

    /// A pasted prompt often carries a newline of its own; only what is
    /// before it is the command.
    func testOnlyTheFirstLineIsTheCommand() {
        XCTAssertEqual(ChannelCommands.parse("/use new\nsecond line"), .use("new"))
    }

    func testAPathKeepsItsSpaces() {
        XCTAssertEqual(ChannelCommands.parse("/send docs/report.md"), .send("docs/report.md"))
        XCTAssertEqual(ChannelCommands.parse("/send a file with spaces.txt"), .send("a file with spaces.txt"))
    }

    /// A sentence that begins with a slash is a message: only the commands
    /// this build knows are commands.
    func testAMessageIsNotACommand() {
        XCTAssertNil(ChannelCommands.parse("你好"))
        XCTAssertNil(ChannelCommands.parse("/unknown"))
    }

    func testEffortSpellings() {
        XCTAssertEqual(ChannelCommands.effort("hi"), .high)
        XCTAssertEqual(ChannelCommands.effort("MID"), .medium)
        XCTAssertEqual(ChannelCommands.effort("lo"), .low)
        XCTAssertNil(ChannelCommands.effort("x"))
        XCTAssertEqual(ChannelCommands.effortName(.high), "hi")
        XCTAssertEqual(ChannelCommands.effortName(.medium), "mid")
    }

    func testOnlyPositiveNumbersIndexAList() {
        XCTAssertEqual(ChannelCommands.index("3"), 3)
        XCTAssertNil(ChannelCommands.index("0"))
        XCTAssertNil(ChannelCommands.index("-1"))
        XCTAssertNil(ChannelCommands.index("abc"))
    }
}
