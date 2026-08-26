import Foundation
import Security

struct AppCodeIdentity: Equatable, Sendable {
    let fingerprint: String
    let isAdHoc: Bool

    static let current: AppCodeIdentity? = loadCurrent()

    private static func loadCurrent() -> AppCodeIdentity? {
        let candidateURLs = [Bundle.main.bundleURL, Bundle.main.executableURL]
            .compactMap { $0 }

        for url in candidateURLs {
            var staticCode: SecStaticCode?
            let createStatus = SecStaticCodeCreateWithPath(
                url as CFURL,
                SecCSFlags(),
                &staticCode
            )
            guard createStatus == errSecSuccess, let staticCode else { continue }

            var signingInformation: CFDictionary?
            let informationStatus = SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInformation
            )
            guard informationStatus == errSecSuccess,
                  let information = signingInformation as NSDictionary?,
                  let uniqueHash = information[kSecCodeInfoUnique] as? Data else {
                continue
            }

            let flags = (information[kSecCodeInfoFlags] as? NSNumber)?.uint32Value ?? 0
            let adHocFlag: UInt32 = 0x0000_0002 // CS_ADHOC from codesign.h
            return AppCodeIdentity(
                fingerprint: uniqueHash.map { String(format: "%02x", $0) }.joined(),
                isAdHoc: flags & adHocFlag != 0
            )
        }

        return nil
    }
}

enum FullDiskAccessConfirmationStatus: Equatable, Sendable {
    case notConfirmed
    case confirmed
    case appIdentityChanged
    case unableToVerify

    static func evaluate(
        probeResult: FullDiskAccessProbeResult,
        onboardingCompleted: Bool,
        confirmedCodeIdentity: String,
        currentCodeIdentity: AppCodeIdentity?
    ) -> Self {
        if probeResult == .granted {
            return .confirmed
        }

        if probeResult == .unavailable {
            return .unableToVerify
        }

        if onboardingCompleted,
           let currentCodeIdentity,
           currentCodeIdentity.isAdHoc,
           confirmedCodeIdentity != currentCodeIdentity.fingerprint {
            return .appIdentityChanged
        }

        return .notConfirmed
    }
}
