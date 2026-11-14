import CommonCrypto
import Foundation

/// The bytes side of the WeChat channel: AES-128-ECB as the iLink CDN takes
/// it, the hashes an upload is described by, and the keys a message carries
/// (2026-11-15).
///
/// Everything is system cryptography — CommonCrypto — and nothing here logs
/// a key.
public enum IlinkMedia {
    /// An upload's ciphertext is the plaintext padded to the next 16-byte
    /// boundary, with at least one byte of padding.
    public static func paddedSize(_ plainSize: Int) -> Int {
        ((plainSize + 1 + 15) / 16) * 16
    }

    public static func md5Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func randomHex(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0 ... 255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// AES-128-ECB with PKCS#7 padding — what the CDN encrypts and decrypts
    /// with.
    public static func crypt(_ data: Data, key: Data, encrypt: Bool) -> Data? {
        guard key.count == kCCKeySizeAES128 else { return nil }
        let outputLength = data.count + kCCBlockSizeAES128
        var output = Data(count: outputLength)
        var written = 0
        let status = output.withUnsafeMutableBytes { outBuffer in
            data.withUnsafeBytes { inBuffer in
                key.withUnsafeBytes { keyBuffer in
                    CCCrypt(
                        CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress,
                        key.count,
                        nil,
                        inBuffer.baseAddress,
                        data.count,
                        outBuffer.baseAddress,
                        outputLength,
                        &written
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }

    /// The 16-byte key an `aes_key` names. Two spellings come over the wire,
    /// as the official plugin's own reader says: base64 of the 16 raw bytes
    /// (images), and base64 of 32 hex characters (files, voice, video).
    public static func key(fromBase64 encoded: String) -> Data? {
        guard let decoded = Data(base64Encoded: encoded) else { return nil }
        if decoded.count == 16 {
            return decoded
        }
        if decoded.count == 32, let text = String(data: decoded, encoding: .utf8),
           text.allSatisfy({ $0.isHexDigit })
        {
            return key(fromHex: text)
        }
        return nil
    }

    public static func key(fromHex hex: String) -> Data? {
        guard hex.count == 32 else { return nil }
        var bytes = Data(capacity: 16)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// The `aes_key` a sent message carries: base64 of the raw key.
    public static func aesKeyField(for key: Data) -> String {
        key.base64EncodedString()
    }
}
