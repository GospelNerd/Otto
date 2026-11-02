import Foundation

/// Makes a WAVE file readable by the speech engines' own wave readers.
///
/// `afconvert` writes a `WAVE_FORMAT_EXTENSIBLE` header (format tag `0xFFFE`, a 40-byte `fmt `
/// chunk) whenever the source carries a channel layout, which Telegram's Ogg Opus voice notes do.
/// sherpa-onnx only accepts the classic 16-byte integer PCM `fmt ` chunk and answers
/// `Failed to read 'clip.wav'` otherwise. This rewrites such a file as plain PCM, keeps the
/// samples byte for byte, and drops `afconvert`'s page-alignment `FLLR` chunk on the way.
enum PCMWaveFile {
  /// `WAVE_FORMAT_EXTENSIBLE`'s sub-format GUID for integer PCM.
  private static let pcmSubformat: [UInt8] = [
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
  ]

  /// Rewrites the file in place when its header needs it; leaves anything else untouched.
  static func normalize(at url: URL) throws {
    let data = try Data(contentsOf: url)
    guard let plain = plainPCM(data) else { return }
    try plain.write(to: url, options: .atomic)
  }

  /// The same integer PCM audio behind a 16-byte `fmt ` chunk followed directly by `data`, or nil
  /// when the file already has that shape or is not an integer PCM WAVE this understands.
  static func plainPCM(_ data: Data) -> Data? {
    let bytes = [UInt8](data)
    guard bytes.count >= 12, tag(bytes, 0) == "RIFF", tag(bytes, 8) == "WAVE" else { return nil }

    var format: (channels: Int, sampleRate: Int, byteRate: Int, blockAlign: Int, bits: Int)?
    var alreadyPlain = false
    var offset = 12
    while offset + 8 <= bytes.count {
      let id = tag(bytes, offset)
      let size = u32(bytes, offset + 4)
      let body = offset + 8
      if id == "fmt " {
        guard body + 16 <= bytes.count, [16, 18, 40].contains(size) else { return nil }
        let audioFormat = u16(bytes, body)
        if audioFormat == 0xFFFE {
          guard size == 40, body + 40 <= bytes.count,
            Array(bytes[(body + 24)..<(body + 40)]) == pcmSubformat
          else { return nil }
        } else if audioFormat == 1 {
          alreadyPlain = size == 16
        } else {
          return nil
        }
        format = (
          channels: u16(bytes, body + 2), sampleRate: u32(bytes, body + 4),
          byteRate: u32(bytes, body + 8), blockAlign: u16(bytes, body + 12),
          bits: u16(bytes, body + 14)
        )
      } else if id == "data" {
        guard let format else { return nil }
        // Only `fmt ` directly followed by `data` needs no rewrite.
        if alreadyPlain, offset == 12 + 8 + 16 { return nil }
        let available = bytes.count - body
        let length = min(size, available)
        var out: [UInt8] = []
        out.reserveCapacity(44 + length)
        out += Array("RIFF".utf8)
        out += le32(36 + length)
        out += Array("WAVE".utf8)
        out += Array("fmt ".utf8)
        out += le32(16)
        out += le16(1)
        out += le16(format.channels)
        out += le32(format.sampleRate)
        out += le32(format.byteRate)
        out += le16(format.blockAlign)
        out += le16(format.bits)
        out += Array("data".utf8)
        out += le32(length)
        out += bytes[body..<(body + length)]
        return Data(out)
      }
      offset = body + size + (size & 1)
    }
    return nil
  }

  private static func tag(_ bytes: [UInt8], _ offset: Int) -> String {
    guard offset + 4 <= bytes.count else { return "" }
    return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
  }

  private static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
  }

  private static func u32(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
      | Int(bytes[offset + 3]) << 24
  }

  private static func le16(_ value: Int) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
  }

  private static func le32(_ value: Int) -> [UInt8] {
    [
      UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24),
    ]
  }
}
