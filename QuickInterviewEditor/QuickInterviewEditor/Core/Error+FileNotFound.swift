import Foundation

extension Error {
  /// True for a plain "no such file" failure, which best-effort readers treat as a normal
  /// miss rather than something worth logging.
  var isFileNotFound: Bool {
    let nsError = self as NSError
    return nsError.domain == NSCocoaErrorDomain
      && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code)
  }
}
