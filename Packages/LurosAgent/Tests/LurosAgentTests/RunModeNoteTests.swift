@testable import LurosAgent
import enum LurosProtocol.AgentRunMode
import struct LurosProtocol.AgentRunModeRequest
import Testing

/// What the model reads after the reader answers a run mode switch: keeping
/// the plan says what to change about it, and starting the build carries the
/// word typed beside Approve into the work.
@Suite("run mode notes")
struct RunModeNoteTests {
    @Test
    func `a plan kept without a note reads as it always did`() {
        let text = RunModes.declined(note: nil)
        #expect(text == RunModes.declined)
        #expect(RunModes.declined(note: "   ").contains("The user added") == false)
    }

    @Test
    func `a note kept with the plan becomes what to change about it`() {
        let text = RunModes.declined(note: "store the size, not the listing")
        #expect(text.hasPrefix(RunModes.declined))
        #expect(text.contains("store the size, not the listing"))
        #expect(text.contains("what the plan should leave out"))
    }

    @Test
    func `a build approved with a note carries it into the work`() {
        let request = AgentRunModeRequest(mode: .build, reason: "the plan is ready")
        let plain = RunModes.changed(request)
        #expect(RunModes.changed(request, note: nil) == plain)
        #expect(RunModes.changed(request, note: "  ") == plain)
        let noted = RunModes.changed(request, note: "one file at a time")
        #expect(noted.hasPrefix(plain))
        #expect(noted.contains("one file at a time"))
    }
}
