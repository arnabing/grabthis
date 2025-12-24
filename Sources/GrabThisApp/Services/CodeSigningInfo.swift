import Foundation
import Security

enum CodeSigningInfo {
    struct Info: Sendable {
        let isSigned: Bool
        let teamID: String?
        let signingIdentifier: String?
        let statusDescription: String
    }

    static func current() -> Info {
        var code: SecCode?
        let selfErr = SecCodeCopySelf(SecCSFlags(), &code)
        guard selfErr == errSecSuccess, let code else {
            return Info(
                isSigned: false,
                teamID: nil,
                signingIdentifier: nil,
                statusDescription: "SecCodeCopySelf failed: \(selfErr)"
            )
        }

        var staticCode: SecStaticCode?
        let staticErr = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard staticErr == errSecSuccess, let staticCode else {
            return Info(
                isSigned: false,
                teamID: nil,
                signingIdentifier: nil,
                statusDescription: "SecCodeCopyStaticCode failed: \(staticErr)"
            )
        }

        var infoRef: CFDictionary?
        let infoErr = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)

        if infoErr == errSecCSUnsigned {
            return Info(
                isSigned: false,
                teamID: nil,
                signingIdentifier: nil,
                statusDescription: "unsigned (errSecCSUnsigned)"
            )
        }

        guard infoErr == errSecSuccess, let dict = infoRef as? [String: Any] else {
            return Info(
                isSigned: false,
                teamID: nil,
                signingIdentifier: nil,
                statusDescription: "SecCodeCopySigningInformation failed: \(infoErr)"
            )
        }

        // Keys are bridged as Strings.
        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let ident = dict[kSecCodeInfoIdentifier as String] as? String

        return Info(
            isSigned: true,
            teamID: teamID,
            signingIdentifier: ident,
            statusDescription: "signed"
        )
    }
}


