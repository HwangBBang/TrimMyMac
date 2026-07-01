import Testing
import Foundation
@testable import TrimCore

@Suite("FullDiskAccessClassifier")
struct FullDiskAccessTests {

    // EPERM (POSIX errno 1) -> true
    @Test func epermErrnoNeedsFullDiskAccess() {
        #expect(FullDiskAccessClassifier.needsFullDiskAccess(errno: EPERM) == true)
    }

    // EACCES (13) also indicates a permission wall -> true
    @Test func eaccesErrnoNeedsFullDiskAccess() {
        #expect(FullDiskAccessClassifier.needsFullDiskAccess(errno: EACCES) == true)
    }

    // A generic "not found" (ENOENT / 2) is NOT a permission problem -> false
    @Test func notFoundErrnoDoesNotNeedFullDiskAccess() {
        #expect(FullDiskAccessClassifier.needsFullDiskAccess(errno: ENOENT) == false)
    }

    // POSIXError.EPERM value -> true
    @Test func posixErrorEPERMNeedsFullDiskAccess() {
        let err: Error = POSIXError(.EPERM)
        #expect(FullDiskAccessClassifier.needsFullDiskAccess(for: err) == true)
    }

    // POSIXError.EACCES value -> true
    @Test func posixErrorEACCESNeedsFullDiskAccess() {
        let err: Error = POSIXError(.EACCES)
        #expect(FullDiskAccessClassifier.needsFullDiskAccess(for: err) == true)
    }

    // Foundation's Cocoa permission error (NSFileReadNoPermissionError = 257) -> true
    @Test func cocoaNoPermissionErrorNeedsFullDiskAccess() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: nil)
        #expect(FullDiskAccessClassifier.needsFullDiskAccess(for: err) == true)
    }

    // EPERM nested under NSUnderlyingErrorKey of a Cocoa error -> true (real shape from FileManager)
    @Test func underlyingPOSIXEPERMNeedsFullDiskAccess() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: nil)
        let err = NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadUnknownError,
                          userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(FullDiskAccessClassifier.needsFullDiskAccess(for: err) == true)
    }

    // A generic "no such file" Cocoa error (260) -> false
    @Test func cocoaNoSuchFileErrorDoesNotNeedFullDiskAccess() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: nil)
        #expect(FullDiskAccessClassifier.needsFullDiskAccess(for: err) == false)
    }
}

@Suite("FullDiskAccessStatus")
struct FullDiskAccessStatusTests {
    @Test func nilErrorIsGranted() {
        #expect(FullDiskAccessStatus.from(probeError: nil) == .granted)
    }
    @Test func epermIsDenied() {
        #expect(FullDiskAccessStatus.from(probeError: POSIXError(.EPERM)) == .denied)
    }
    @Test func eaccesIsDenied() {
        #expect(FullDiskAccessStatus.from(probeError: POSIXError(.EACCES)) == .denied)
    }
    @Test func cocoaNoPermissionIsDenied() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        #expect(FullDiskAccessStatus.from(probeError: err) == .denied)
    }
    @Test func enoentIsUnknownNotGranted() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect(FullDiskAccessStatus.from(probeError: err) == .unknown)
    }
}

@Suite("FullDiskAccessGate")
struct FullDiskAccessGateTests {
    @Test func onboardingOnlyWhenDeniedAndUnseen() {
        #expect(FullDiskAccessGate.shouldShowOnboarding(seen: false, status: .denied) == true)
        #expect(FullDiskAccessGate.shouldShowOnboarding(seen: true,  status: .denied) == false)
        #expect(FullDiskAccessGate.shouldShowOnboarding(seen: false, status: .granted) == false)
        #expect(FullDiskAccessGate.shouldShowOnboarding(seen: false, status: .unknown) == false)
    }
    @Test func affordanceMapping() {
        #expect(FullDiskAccessGate.affordance(for: .denied) == .strip)
        #expect(FullDiskAccessGate.affordance(for: .unknown) == .quietLink)
        #expect(FullDiskAccessGate.affordance(for: .granted) == .hidden)
    }
}
