import XCTest
@testable import MoriPhotos

final class OneDriveWebTests: XCTestCase {
    func testAllowsOneDriveAndMicrosoftLoginRedirects() {
        for value in ["https://onedrive.live.com/", "https://login.live.com/oauth20_authorize.srf", "https://login.microsoftonline.com/common/oauth2/v2.0/authorize", "https://tenant.sharepoint.com/files", "https://www.office.com/", "https://onedrive.live.com:443/", "https://onedrive.cloud.microsoft/", "https://m365.cloud.microsoft/"] {
            XCTAssertTrue(OneDriveWebPolicy.allows(URL(string: value)!))
        }
    }
    func testRejectsLookalikeHostsAndNonMicrosoftSites() {
        for value in ["https://live.com.attacker.example/", "https://evil-live.com/", "https://microsoftonline.com.attacker.example/", "https://example.com/", "https://cloud.microsoft.attacker.example/"] {
            XCTAssertFalse(OneDriveWebPolicy.allows(URL(string: value)!))
        }
    }
    func testRejectsInsecureSchemesCredentialsAndUnexpectedPorts() {
        for value in ["http://onedrive.live.com/", "file:///tmp/file", "javascript:alert(1)", "https://user:password@onedrive.live.com/", "https://onedrive.live.com:8443/"] {
            XCTAssertFalse(OneDriveWebPolicy.allows(URL(string: value)!))
        }
    }
}
