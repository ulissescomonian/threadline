enum HexEncoding {
    /// Canonical lowercase hex without constructing a Foundation formatter
    /// for every byte. These bytes are part of persisted and sync identities.
    static func lowercaseString(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
