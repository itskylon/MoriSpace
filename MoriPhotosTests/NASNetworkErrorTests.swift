import XCTest
@testable import MoriPhotos

final class NASNetworkErrorTests: XCTestCase {
    func testPreviouslyCollapsedFailuresHaveDistinctReasonsAndExactCodes() {
        let cases: [(URLError.Code, String)] = [
            (.timedOut, "超时"),
            (.cannotFindHost, "解析 NAS 域名"),
            (.dnsLookupFailed, "解析 NAS 域名"),
            (.cannotConnectToHost, "地址或端口"),
            (.notConnectedToInternet, "当前 App 无法使用网络")
        ]
        let messages = cases.map { code, reason in
            let message = friendlyError(URLError(code))
            XCTAssertTrue(message.contains(reason))
            XCTAssertTrue(message.contains("（\(code.rawValue)）"))
            return message
        }
        XCTAssertEqual(Set(messages).count, cases.count)
    }

    func testUnavailableNetworkSuggestsConditionalPermissionsWithoutClaimingDenial() {
        let message = friendlyError(URLError(.notConnectedToInternet))
        XCTAssertTrue(message.contains("使用蜂窝网络时"))
        XCTAssertTrue(message.contains("访问局域网 NAS 时"))
        XCTAssertTrue(message.contains("本地网络"))
        XCTAssertFalse(message.contains("权限已被拒绝"))
        XCTAssertFalse(message.contains("权限被关闭"))
    }

    func testTLSHandshakeAndCertificateFailuresRemainDistinct() {
        let handshake = friendlyError(URLError(.secureConnectionFailed))
        XCTAssertTrue(handshake.contains("-1200"))
        XCTAssertTrue(handshake.contains("TLS 握手失败"))
        XCTAssertFalse(handshake.contains("证书验证失败"))
        for code: URLError.Code in [.serverCertificateHasBadDate, .serverCertificateUntrusted,
                                    .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid] {
            let message = friendlyError(URLError(code))
            XCTAssertTrue(message.contains("证书验证失败"))
            XCTAssertTrue(message.contains("（\(code.rawValue)）"))
            XCTAssertFalse(message.contains("TLS 握手失败"))
        }
    }

    func testCancellationConnectionLossAndDataRestrictionHaveActionableSeparateMessages() {
        let cancelled = friendlyError(URLError(.cancelled))
        XCTAssertEqual(cancelled, "连接已取消（-999）。")
        XCTAssertFalse(cancelled.contains("失败"))
        XCTAssertTrue(friendlyError(URLError(.networkConnectionLost)).contains("网络连接已中断（-1005）"))
        XCTAssertTrue(friendlyError(URLError(.dataNotAllowed)).contains("不允许此请求使用当前数据网络（-1020）"))
    }

    func testNetworkMessagesNeverExposeErrorDescriptionsURLsOrNestedCredentials() {
        let marker = "sensitive-sentinel-do-not-show"
        let privateURL = "https://user:\(marker)@example.invalid/webapi/entry.cgi?_sid=\(marker)"
        let nested = NSError(domain: NSPOSIXErrorDomain, code: 54, userInfo: [NSLocalizedDescriptionKey: marker])
        for code: URLError.Code in [.timedOut, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                                    .notConnectedToInternet, .secureConnectionFailed, .serverCertificateUntrusted,
                                    .cancelled, .networkConnectionLost, .dataNotAllowed, .clientCertificateRequired,
                                    .badServerResponse, .unknown] {
            let error = NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [
                NSLocalizedDescriptionKey: marker,
                NSURLErrorFailingURLStringErrorKey: privateURL,
                NSURLErrorFailingURLErrorKey: URL(string: privateURL)!,
                NSUnderlyingErrorKey: nested
            ])
            let message = friendlyError(error)
            XCTAssertTrue(message.contains(String(code.rawValue)))
            XCTAssertFalse(message.contains(marker))
            XCTAssertFalse(message.contains("example.invalid"))
            XCTAssertFalse(message.contains("_sid"))
        }
    }
}
