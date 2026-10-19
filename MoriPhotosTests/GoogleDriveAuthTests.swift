import XCTest
import GoogleSignIn
@testable import MoriPhotos

@MainActor
final class GoogleDriveAuthTests: XCTestCase {
    private let clientID = "1234567890-testclient.apps.googleusercontent.com"
    private let scheme = "com.googleusercontent.apps.1234567890-testclient"

    private func info(client: String? = nil, schemes: [String]? = nil) -> [String: Any] {
        ["GIDClientID": client ?? clientID,
         "CFBundleURLTypes": [["CFBundleURLName": "calendar", "CFBundleURLSchemes": ["morispace"]],
                              ["CFBundleURLName": "google", "CFBundleURLSchemes": schemes ?? [scheme]]]]
    }

    func testOAuthConfigurationPreservesCalendarSchemeAndFindsGoogleCallback() throws {
        let configuration = try XCTUnwrap(GoogleDriveOAuthConfiguration(info: info()))
        XCTAssertEqual(configuration.clientID, clientID)
        XCTAssertEqual(configuration.callbackScheme, scheme)
    }

    func testRejectsMissingOrMismatchedCallbackInsteadOfStartingAnUnreturnableSignIn() {
        XCTAssertNil(GoogleDriveOAuthConfiguration(info: ["GIDClientID": clientID]))
        XCTAssertNil(GoogleDriveOAuthConfiguration(info: info(schemes: ["morispace"])))
        XCTAssertNil(GoogleDriveOAuthConfiguration(info: info(schemes: [scheme + ".different"])))
    }

    func testRejectsEmailWebsiteAndUnexpandedBuildSettingAsClientID() {
        for candidate in ["", "person@example.com", "https://drive.google.com/drive/u/0/home", "$(MORI_GOOGLE_CLIENT_ID)",
                          "1234567890-testclient.apps.googleusercontent.com.attacker.invalid", "1234567890-testclient.apps.googleusercontent.com/path"] {
            XCTAssertNil(GoogleDriveOAuthConfiguration(info: info(client: candidate)))
        }
        XCTAssertEqual(GoogleDriveOAuthConfiguration.validatedClientID(" \n" + clientID + "\n "), clientID)
    }

    func testRevokedGrantRequiresSignInButTransientConnectionFailureDoesNot() {
        let revoked = NSError(domain: "org.openid.appauth.oauth_token", code: -3,
                              userInfo: ["OIDOAuthErrorResponseErrorKey": ["error": "invalid_grant"]])
        let wrapped = NSError(domain: "GoogleDriveTest", code: 1, userInfo: [NSUnderlyingErrorKey: revoked])
        XCTAssertTrue(GoogleDriveAuth.requiresNewSignIn(revoked))
        XCTAssertTrue(GoogleDriveAuth.requiresNewSignIn(wrapped))
        XCTAssertTrue(GoogleDriveAuth.requiresNewSignIn(NSError(domain: kGIDSignInErrorDomain,
                                                             code: GIDSignInError.hasNoAuthInKeychain.rawValue)))
        XCTAssertTrue(GoogleDriveAuth.requiresNewSignIn(NSError(domain: kGIDSignInErrorDomain,
                                                             code: GIDSignInError.refreshTokenExpired.rawValue)))
        XCTAssertFalse(GoogleDriveAuth.requiresNewSignIn(URLError(.notConnectedToInternet)))
        XCTAssertFalse(GoogleDriveAuth.requiresNewSignIn(NSError(domain: "org.openid.appauth.oauth_token", code: 503,
                                                               userInfo: ["OIDOAuthErrorResponseErrorKey": ["error": "temporarily_unavailable"]])))
        XCTAssertFalse(GoogleDriveAuth.requiresNewSignIn(NSError(domain: kGIDSignInErrorDomain,
                                                               code: GIDSignInError.canceled.rawValue)))
    }
}
