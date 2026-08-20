import Foundation

@main
enum UploadEncryptionTests {
    static func main() throws {
        try nistAES256CTRVector()
        try chunkOffsetsMatchSinglePass()
        try rejectsInvalidMetadata()
        print("UploadEncryptionTests: all tests passed")
    }

    /// NIST SP 800-38A F.5.5 AES-256 CTR test vector.
    private static func nistAES256CTRVector() throws {
        let encryptor = try makeEncryptor(
            key: hex("603deb1015ca71be2b73aef0857d7781" +
                "1f352c073b6108d72d9810a30914dff4"),
            iv: hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"))
        let plaintext = hex(
            "6bc1bee22e409f96e93d7e117393172a" +
            "ae2d8a571e03ac9c9eb76fac45af8e51" +
            "30c81c46a35ce411e5fbc1191a0a52ef" +
            "f69f2445df4f9b17ad2b417be66c3710")
        let expected = hex(
            "601ec313775789a5b7a7f504bbf3d228" +
            "f443e3ca4d62b59aca84e990cacaf5c5" +
            "2b0930daa23de94ce87017ba2d84988d" +
            "dfc9c58db67aada613c2dd08457941a6")
        let actual = try encryptor.encrypt(plaintext, at: 0)
        precondition(actual == expected)
    }

    private static func chunkOffsetsMatchSinglePass() throws {
        let encryptor = try makeEncryptor(
            key: Data((0..<32).map(UInt8.init)),
            iv: Data((0..<16).reversed().map(UInt8.init)))
        let plaintext = Data((0..<197).map { UInt8(($0 * 29) & 0xff) })
        let expected = try encryptor.encrypt(plaintext, at: 0)

        for chunkSize in [1, 7, 16, 23, 64] {
            var actual = Data()
            var offset = 0
            while offset < plaintext.count {
                let end = min(offset + chunkSize, plaintext.count)
                actual.append(
                    try encryptor.encrypt(plaintext.subdata(in: offset..<end), at: UInt64(offset)))
                offset = end
            }
            precondition(actual == expected, "chunk size \(chunkSize) changed ciphertext")
        }
    }

    private static func rejectsInvalidMetadata() throws {
        let json = Data(
            #"{"algorithm":"not-a-cipher","key_plain_text":"AA==","iv":"AA=="}"#.utf8)
        let metadata = try JSONDecoder().decode(UploadEncryptMetadata.self, from: json)
        do {
            _ = try UploadEncryptor(metadata: metadata)
            preconditionFailure("unsupported encryption algorithm was accepted")
        } catch UploadEncryptionError.unsupportedAlgorithm {
            // Expected.
        }
    }

    private static func makeEncryptor(key: Data, iv: Data) throws -> UploadEncryptor {
        let json = Data(
            "{\"algorithm\":\"aes-256-ctr\",\"key_plain_text\":\"\(key.base64EncodedString())\",\"iv\":\"\(iv.base64EncodedString())\"}".utf8)
        return try UploadEncryptor(
            metadata: JSONDecoder().decode(UploadEncryptMetadata.self, from: json))
    }

    private static func hex(_ string: String) -> Data {
        var result = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            result.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return result
    }
}
