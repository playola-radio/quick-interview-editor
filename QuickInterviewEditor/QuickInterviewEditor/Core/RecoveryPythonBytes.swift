import Foundation

enum RecoveryPythonBytes {
  private struct Member {
    var key: String
    var keyStart: Int
    var value: Range<Int>
  }

  static func verifyIntegrity(_ data: Data) throws {
    let bytes = Array(data)
    let members = try members(bytes)
    guard let index = members.firstIndex(where: { $0.key == "integrity" }) else {
      throw SuggestionRecoveryError.invalid("Missing Python integrity digest.")
    }
    let digest = try JSONDecoder().decode(String.self, from: Data(bytes[members[index].value]))
    let removal: Range<Int>
    if index + 1 < members.count {
      removal = members[index].keyStart..<members[index + 1].keyStart
    } else if index > 0 {
      removal = members[index - 1].value.upperBound..<members[index].value.upperBound
    } else {
      removal = members[index].keyStart..<members[index].value.upperBound
    }
    let original = Data(bytes[..<removal.lowerBound] + bytes[removal.upperBound...])
    guard SuggestionRecoveryArchive.sha256(original) == digest else {
      throw SuggestionRecoveryError.invalid(
        "Python integrity digest does not match its original bytes.")
    }
  }

  static func value(_ key: String, in data: Data) throws -> Data {
    let bytes = Array(data)
    guard let member = try members(bytes).first(where: { $0.key == key }) else {
      throw SuggestionRecoveryError.invalid("Missing Python field \(key).")
    }
    return Data(bytes[member.value])
  }

  private static func members(_ bytes: [UInt8]) throws -> [Member] {
    _ = try RecoveryJSON.read(Data(bytes))
    var index = 0
    skipWhitespace(bytes, index: &index)
    guard index < bytes.count, bytes[index] == 123 else { throw malformed() }
    index += 1
    var result: [Member] = []
    var keys = Set<String>()
    while index < bytes.count {
      skipWhitespace(bytes, index: &index)
      if bytes[index] == 125 { return result }
      let start = index
      try stringEnd(bytes, index: &index)
      let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
      guard keys.insert(key).inserted else { throw malformed() }
      skipWhitespace(bytes, index: &index)
      guard index < bytes.count, bytes[index] == 58 else { throw malformed() }
      index += 1
      skipWhitespace(bytes, index: &index)
      let valueStart = index
      try valueEnd(bytes, index: &index)
      var end = index
      while end > valueStart, isWhitespace(bytes[end - 1]) { end -= 1 }
      guard end > valueStart, index < bytes.count else { throw malformed() }
      result.append(Member(key: key, keyStart: start, value: valueStart..<end))
      if bytes[index] == 125 { return result }
      index += 1
    }
    throw malformed()
  }

  private static func valueEnd(_ bytes: [UInt8], index: inout Int) throws {
    var depth = 0
    while index < bytes.count {
      let byte = bytes[index]
      if byte == 34 {
        try stringEnd(bytes, index: &index)
        continue
      }
      if depth == 0 && (byte == 44 || byte == 125) { break }
      if byte == 123 || byte == 91 { depth += 1 }
      if byte == 125 || byte == 93 { depth -= 1 }
      index += 1
    }
  }

  private static func stringEnd(_ bytes: [UInt8], index: inout Int) throws {
    guard index < bytes.count, bytes[index] == 34 else { throw malformed() }
    index += 1
    while index < bytes.count {
      if bytes[index] == 92 {
        index += 2
        continue
      }
      if bytes[index] == 34 {
        index += 1
        return
      }
      index += 1
    }
    throw malformed()
  }

  private static func skipWhitespace(_ bytes: [UInt8], index: inout Int) {
    while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
  }
  private static func isWhitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
  private static func malformed() -> SuggestionRecoveryError {
    .invalid("Malformed Python object members.")
  }
}
