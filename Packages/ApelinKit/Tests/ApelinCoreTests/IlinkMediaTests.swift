import ApelinCore
import ApelinProtocol
import Foundation
import XCTest

/// The bytes side of the WeChat channel: AES-128-ECB as the CDN takes it,
/// the two spellings of `aes_key`, and the hashes an upload is described by
/// (2026-11-15).
final class IlinkMediaTests: XCTestCase {
    func testCiphertextIsThePaddedSize() {
        XCTAssertEqual(IlinkMedia.paddedSize(0), 16)
        XCTAssertEqual(IlinkMedia.paddedSize(1), 16)
        XCTAssertEqual(IlinkMedia.paddedSize(16), 32)
        XCTAssertEqual(IlinkMedia.paddedSize(17), 32)
    }

    func testMD5IsTheOneTheTicketTakes() {
        XCTAssertEqual(IlinkMedia.md5Hex(Data("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testKeysAreReadInBothSpellings() {
        let raw = Data((0 ..< 16).map { UInt8($0 * 7 + 1) })
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        // Images carry base64 of the raw bytes; files carry base64 of the
        // 32 hex characters.
        XCTAssertEqual(IlinkMedia.key(fromBase64: raw.base64EncodedString()), raw)
        XCTAssertEqual(IlinkMedia.key(fromBase64: Data(hex.utf8).base64EncodedString()), raw)
        XCTAssertEqual(IlinkMedia.key(fromHex: hex), raw)
        XCTAssertNil(IlinkMedia.key(fromHex: "zz"))
        XCTAssertEqual(IlinkMedia.aesKeyField(for: raw), raw.base64EncodedString())
    }

    func testACipherRoundTrips() throws {
        let key = Data((0 ..< 16).map { UInt8($0 * 7 + 1) })
        let plain = Data("微信里发过来的一段文字".utf8)
        let cipher = try XCTUnwrap(IlinkMedia.crypt(plain, key: key, encrypt: true))
        XCTAssertEqual(cipher.count, IlinkMedia.paddedSize(plain.count))
        XCTAssertEqual(IlinkMedia.crypt(cipher, key: key, encrypt: false), plain)
        XCTAssertNil(IlinkMedia.crypt(plain, key: Data(repeating: 0, count: 8), encrypt: true))
    }

    func testTheMediaTypeFollowsTheName() {
        XCTAssertEqual(IlinkMediaType.of(name: "a.JPG"), .image)
        XCTAssertEqual(IlinkMediaType.of(name: "clip.mov"), .video)
        XCTAssertEqual(IlinkMediaType.of(name: "notes.md"), .file)
    }
}
