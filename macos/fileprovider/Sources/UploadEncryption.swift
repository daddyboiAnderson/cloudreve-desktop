import CommonCrypto
import Foundation

enum UploadEncryptionError: LocalizedError {
    case unsupportedAlgorithm(String)
    case invalidKey
    case invalidIV
    case cryptorFailure(CCCryptorStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedAlgorithm(let algorithm):
            return "Unsupported Cloudreve upload encryption algorithm: \(algorithm)"
        case .invalidKey:
            return "Cloudreve returned an invalid upload encryption key"
        case .invalidIV:
            return "Cloudreve returned an invalid upload encryption IV"
        case .cryptorFailure(let status):
            return "AES upload encryption failed (CommonCrypto status \(status))"
        }
    }
}

/// Cloudreve's per-file encryption parameters returned with an upload session.
struct UploadEncryptMetadata: Decodable {
    let algorithm: String
    let keyPlainText: String
    let iv: String

    private enum CodingKeys: String, CodingKey {
        case algorithm
        case cipher
        case keyPlainText = "key_plain_text"
        case iv
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        algorithm =
            try container.decodeIfPresent(String.self, forKey: .algorithm)
            ?? container.decode(String.self, forKey: .cipher)
        keyPlainText = try container.decode(String.self, forKey: .keyPlainText)
        iv = try container.decode(String.self, forKey: .iv)
    }
}

/// AES-256-CTR compatible with Cloudreve's Rust and Web uploaders.
struct UploadEncryptor {
    static let supportedAlgorithm = "aes-256-ctr"

    private let key: Data
    private let initialCounter: [UInt8]

    init(metadata: UploadEncryptMetadata) throws {
        guard metadata.algorithm == Self.supportedAlgorithm else {
            throw UploadEncryptionError.unsupportedAlgorithm(metadata.algorithm)
        }
        guard let key = Data(base64Encoded: metadata.keyPlainText), key.count == kCCKeySizeAES256
        else {
            throw UploadEncryptionError.invalidKey
        }
        guard let iv = Data(base64Encoded: metadata.iv), iv.count == kCCBlockSizeAES128 else {
            throw UploadEncryptionError.invalidIV
        }
        self.key = key
        self.initialCounter = Array(iv)
    }

    /// Encrypts bytes at their absolute offset within the source file. CTR has
    /// no padding, so the encrypted output is always the same size as `data`.
    func encrypt(_ data: Data, at byteOffset: UInt64) throws -> Data {
        guard !data.isEmpty else { return data }

        let offsetInBlock = Int(byteOffset % UInt64(kCCBlockSizeAES128))
        let blockOffset = byteOffset / UInt64(kCCBlockSizeAES128)
        let blockCount = (offsetInBlock + data.count + kCCBlockSizeAES128 - 1)
            / kCCBlockSizeAES128

        var counters = Data(capacity: blockCount * kCCBlockSizeAES128)
        var counter = initialCounter
        add(blockOffset, to: &counter)
        for _ in 0..<blockCount {
            counters.append(contentsOf: counter)
            add(1, to: &counter)
        }

        var keyStream = Data(count: counters.count + kCCBlockSizeAES128)
        let outputCapacity = keyStream.count
        var encryptedLength = 0
        let status = key.withUnsafeBytes { keyBytes in
            counters.withUnsafeBytes { counterBytes in
                keyStream.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode), keyBytes.baseAddress, key.count,
                        nil, counterBytes.baseAddress, counters.count,
                        outputBytes.baseAddress, outputCapacity, &encryptedLength)
                }
            }
        }
        guard status == kCCSuccess else {
            throw UploadEncryptionError.cryptorFailure(status)
        }
        keyStream.count = encryptedLength

        var encrypted = Data(count: data.count)
        encrypted.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                keyStream.withUnsafeBytes { streamBytes in
                    guard
                        let output = outputBytes.bindMemory(to: UInt8.self).baseAddress,
                        let input = inputBytes.bindMemory(to: UInt8.self).baseAddress,
                        let stream = streamBytes.bindMemory(to: UInt8.self).baseAddress
                    else { return }
                    for index in 0..<data.count {
                        output[index] = input[index] ^ stream[offsetInBlock + index]
                    }
                }
            }
        }
        return encrypted
    }

    /// Adds to the low end of Cloudreve's big-endian 128-bit CTR counter.
    private func add(_ value: UInt64, to counter: inout [UInt8]) {
        var carry = value
        for index in counter.indices.reversed() {
            guard carry != 0 else { break }
            let sum = UInt64(counter[index]) + (carry & 0xff)
            counter[index] = UInt8(sum & 0xff)
            carry = (carry >> 8) + (sum >> 8)
        }
    }
}
