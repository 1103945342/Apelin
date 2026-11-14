import ApelinCore
import Foundation
import XCTest

/// The far side of the wire: what WeChat's answers read as, and how a reply
/// is cut into messages (2026-11).
///
/// The fixtures are the shapes the iLink bot API answers with, as the
/// official plugin's own types describe them: a 64-bit `message_id` that is
/// a JSON number, bytes fields as base64 strings, and a text item nested
/// under `item_list`.
final class IlinkTests: XCTestCase {
    func testQRCodeReadsTheOfficialAnswer() throws {
        let json = #"{"qrcode":"1ccfd3636804430c2270f53cecf8be85","qrcode_img_content":"https://liteapp.weixin.qq.com/q/7GiQu1?qrcode=1ccfd3636804430c2270f53cecf8be85&bot_type=3","ret":0}"#
        let code = try JSONCoding.decode(IlinkQRCode.self, from: Data(json.utf8))
        XCTAssertEqual(code.qrcode, "1ccfd3636804430c2270f53cecf8be85")
        XCTAssertTrue(code.content.hasPrefix("https://liteapp.weixin.qq.com/q/"))
    }

    func testLoginPollCarriesTheCredential() throws {
        let json = #"""
        {"status":"confirmed","bot_token":"token-value","ilink_bot_id":"bot@im.bot",
         "ilink_user_id":"user@im.wechat","baseurl":"https://ilinkai.weixin.qq.com"}
        """#
        let poll = try JSONCoding.decode(IlinkLoginPoll.self, from: Data(json.utf8))
        XCTAssertEqual(poll.status, .confirmed)
        XCTAssertEqual(poll.botID, "bot@im.bot")
        XCTAssertEqual(poll.baseURL, "https://ilinkai.weixin.qq.com")
        // A token is the credential: it is read, and never described.
        XCTAssertEqual(poll.botToken, "token-value")
    }

    func testLoginStatusReadsEveryCaseTheServerSends() throws {
        for (raw, expected) in [
            ("wait", IlinkLoginStatus.wait),
            ("scaned", .scaned),
            ("confirmed", .confirmed),
            ("expired", .expired),
            ("scaned_but_redirect", .scanedButRedirect),
            ("need_verifycode", .needVerifyCode),
            ("verify_code_blocked", .verifyCodeBlocked),
            ("binded_redirect", .bindedRedirect),
        ] {
            let json = #"{"status":"\#(raw)"}"#
            let poll = try JSONCoding.decode(IlinkLoginPoll.self, from: Data(json.utf8))
            XCTAssertEqual(poll.status, expected, raw)
        }
    }

    func testUpdatesReadMessagesAndTheirText() throws {
        let json = #"""
        {"ret":0,"get_updates_buf":"buf-2","longpolling_timeout_ms":35000,
         "msgs":[
           {"message_id":7351234567890123456,"from_user_id":"user@im.wechat","to_user_id":"bot@im.bot",
            "message_type":1,"context_token":"ctx-1",
            "item_list":[{"type":1,"text_item":{"text":"你好"}}]},
           {"message_id":"7351234567890123457","from_user_id":"bot@im.bot","message_type":2,
            "item_list":[{"type":1,"text_item":{"text":"a reply of our own"}}]},
           {"message_id":7351234567890123458,"from_user_id":"user@im.wechat","message_type":1,
            "item_list":[{"type":3,"voice_item":{"text":"语音转写"}}]}
         ]}
        """#
        let updates = try JSONCoding.decode(IlinkUpdates.self, from: Data(json.utf8))
        XCTAssertEqual(updates.messages.count, 3)
        XCTAssertEqual(updates.buffer, "buf-2")
        XCTAssertEqual(updates.longPollingTimeoutMilliseconds, 35000)
        // A 64-bit id read as a number would lose its last digits.
        XCTAssertEqual(updates.messages[0].messageID, "7351234567890123456")
        XCTAssertEqual(updates.messages[0].messageType, .user)
        XCTAssertEqual(updates.messages[0].contextToken, "ctx-1")
        XCTAssertEqual(updates.messages[0].readableText, "你好")
        XCTAssertEqual(updates.messages[1].messageType, .bot)
        XCTAssertEqual(updates.messages[2].readableText, "语音转写")
    }

    func testAMessageWithoutTextReadsAsNothing() throws {
        let json = #"""
        {"message_id":"1","from_user_id":"user@im.wechat","message_type":1,
         "item_list":[{"type":2,"image_item":{"url":"https://example.invalid/a.jpg"}}]}
        """#
        let message = try JSONCoding.decode(IlinkMessage.self, from: Data(json.utf8))
        XCTAssertNil(message.readableText)
    }

    func testSendMessageEncodesWhatTheApiTakes() throws {
        let message = IlinkMessage(
            fromUserID: "",
            toUserID: "user@im.wechat",
            clientID: "client-1",
            messageType: .bot,
            messageState: .finish,
            items: [IlinkMessageItem(type: .text, text: "答")],
            contextToken: "ctx-1"
        )
        let encoded = try JSONCoding.encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["message_type"] as? Int, 2)
        XCTAssertEqual(object["message_state"] as? Int, 2)
        XCTAssertEqual(object["from_user_id"] as? String, "")
        XCTAssertEqual(object["to_user_id"] as? String, "user@im.wechat")
        XCTAssertEqual(object["context_token"] as? String, "ctx-1")
        let items = try XCTUnwrap(object["item_list"] as? [[String: Any]])
        XCTAssertEqual(items.first?["type"] as? Int, 1)
        XCTAssertEqual((items.first?["text_item"] as? [String: Any])?["text"] as? String, "答")
    }

}
