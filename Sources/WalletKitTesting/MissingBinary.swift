import XCTest

/// Skips the running test when a node binary isn't installed, so a machine
/// without the local node toolchain doesn't fail.
func skipTestForMissingBinary(_ description: String) throws -> Never {
    throw XCTSkip(description)
}
