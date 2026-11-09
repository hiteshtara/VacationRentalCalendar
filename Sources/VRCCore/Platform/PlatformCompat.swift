import Foundation

// Differences between Darwin Foundation and swift-corelibs-foundation, kept in
// one file so the business rules never have to know about them.
//
// Nothing here changes behaviour. Each declaration exists because a type the
// code already used is spelled differently, or lives elsewhere, on Linux.

#if canImport(FoundationNetworking)
// URLSession, URLRequest and URLResponse moved out of Foundation on Linux.
// Re-exported so every file that fetches a feed does not need its own guard.
@_exported import FoundationNetworking
#endif

#if !canImport(Security)
/// `OSStatus` is a Darwin type. `FeedCredentialError.keychainFailure` carries
/// one, and the error enum itself is portable — only the Keychain
/// implementation that produces the code is Apple-only. Aliasing it to its
/// actual underlying type keeps the error's shape identical on both platforms
/// rather than forcing a second error enum.
public typealias OSStatus = Int32
#endif
