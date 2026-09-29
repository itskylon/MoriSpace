import Foundation

struct NASCredentials: Codable, Equatable {
    var address = ""
    var username = ""
    var password = ""
}

enum PhotoSpace: String, CaseIterable, Identifiable {
    case personal, shared
    var id: String { rawValue }
    var title: String { self == .personal ? "个人空间" : "共享空间" }
    var api: String { self == .personal ? "SYNO.Foto" : "SYNO.FotoTeam" }
}

struct NASPhoto: Decodable, Identifiable, Hashable {
    let id: Int
    let filename: String
    let filesize: Int64?
    let time: Double?
    let type: String?
    let additional: Additional?
    struct Additional: Decodable, Hashable {
        let thumbnail: Thumbnail?
        let resolution: Resolution?
    }
    struct Thumbnail: Decodable, Hashable {
        let cache_key: String?
        let unit_id: Int?
    }
    struct Resolution: Decodable, Hashable { let width: Int; let height: Int }
    var date: Date? { time.map(Date.init(timeIntervalSince1970:)) }
    var isVideo: Bool { type == "video" }
}

struct NASFolder: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let parent: Int?
    var title: String { name == "/" ? "根目录" : (name as NSString).lastPathComponent }
}

struct NASList<T: Decodable>: Decodable { let list: [T] }
struct APIInfo: Decodable { let path: String; let minVersion: Int; let maxVersion: Int; let requestFormat: String? }
struct APIEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: APIErrorCode?
}
struct APIErrorCode: Decodable {
    let code: Int
    let errors: [FileErrorDetail]?
    struct FileErrorDetail: Decodable { let code: Int }
    var fileCode: Int { errors?.first?.code ?? code }
}
struct LoginResponse: Decodable { let sid: String; let synotoken: String? }
struct EmptyResponse: Decodable {}

enum NASError: LocalizedError {
    case invalidAddress, insecureAddress, quickConnect, unsupported(String), api(Int), http(Int), invalidResponse, redirect, invalidImage
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入完整的 NAS HTTPS 地址，例如 https://nas.example.com:5001。"
        case .insecureAddress: return "请使用 HTTPS 地址，以加密传输账号和照片。"
        case .quickConnect: return "第一版不支持 QuickConnect 中继。请填写可直连的 HTTPS 域名或局域网地址。"
        case .unsupported(let api): return "NAS 未提供 \(api) 接口。请确认 DSM 7、Synology Photos 套件及账号权限。"
        case .api(let code):
            switch code {
            case 400: return "账号或密码不正确（400）。"
            case 401: return "账号已停用（401）。"
            case 402: return "此账号没有访问权限（402）。"
            case 403: return "此账号需要双重验证，请输入验证码（403）。"
            case 404: return "双重验证失败，请重新输入当前验证码（404）。"
            case 406: return "需要完成群晖账号的双重验证设置（406）。"
            case 407: return "当前网络的 IP 地址已被 NAS 封锁（407）。请通过仍可登录 DSM 的设备，在“控制面板 → 安全性 → 防护 → 允许/封锁列表”中检查并解除对应 IP 的封锁，再重试。"
            case 408, 409: return "密码已过期（\(code)）。请先在 DSM 中更新密码，再使用新密码连接。"
            case 410: return "此账号必须更改密码（410）。请先在 DSM 中完成密码更新。"
            case 105: return "账号没有访问该空间或照片的权限（105）。"
            case 106, 107: return "登录已过期，请在连接设置中重新登录（\(code)）。"
            case 119: return "NAS 未接受当前登录会话（119），照片尚未载入。请在连接设置中重新登录。"
            default: return "群晖接口返回错误 \(code)。请检查套件版本和账号权限。"
            }
        case .http(let status): return "服务器返回 HTTP \(status)。请检查地址、端口和反向代理设置。"
        case .invalidResponse: return "服务器响应格式不正确。请使用 DSM 地址或 Photos 的 /photo 地址。"
        case .redirect: return "服务器发生重定向。请直接填写最终的 HTTPS 地址。"
        case .invalidImage: return "返回内容不是可读取的照片，可能未生成缩略图或此文件格式暂不支持。"
        }
    }
}

func friendlyError(_ error: Error) -> String {
    if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileWriteOutOfSpaceError {
        return "本机存储空间不足，请释放空间后重试。"
    }
    if let error = error as? URLError {
        let code = "（\(error.code.rawValue)）"
        switch error.code {
        case .cancelled:
            return "连接已取消\(code)。"
        case .timedOut:
            return "连接 NAS 超时\(code)。请确认同一网络下该地址与端口能响应，然后重试。"
        case .cannotFindHost, .dnsLookupFailed:
            return "无法解析 NAS 域名\(code)。请检查地址拼写、DNS 或当前 VPN 的域名解析。"
        case .cannotConnectToHost:
            return "无法连接 NAS 的地址或端口\(code)。请检查 NAS 的 HTTPS 服务、端口以及当前 VPN 或代理设置。"
        case .notConnectedToInternet:
            return "当前 App 无法使用网络\(code)。请检查网络连接；使用蜂窝网络时检查森空间的蜂窝数据权限，访问局域网 NAS 时检查“本地网络”权限。"
        case .networkConnectionLost:
            return "与 NAS 的网络连接已中断\(code)。请等待网络稳定后重试；切换 Wi-Fi、蜂窝网络或 VPN 也可能中断请求。"
        case .dataNotAllowed:
            return "系统不允许此请求使用当前数据网络\(code)。请检查森空间的蜂窝数据权限，或切换到可用的 Wi-Fi 后重试。"
        case .secureConnectionFailed:
            return "无法与 NAS 建立 HTTPS 安全连接\(code)，TLS 握手失败。请检查 NAS 的 HTTPS 服务、端口以及当前 VPN 或代理设置，再重试。"
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "NAS 的 HTTPS 证书验证失败\(code)。请检查证书有效期、域名与信任链，以及本机日期和时间。"
        case .clientCertificateRequired, .clientCertificateRejected:
            return "NAS 要求有效的客户端证书\(code)。请检查服务器的 HTTPS 客户端证书设置。"
        case .badServerResponse:
            return "NAS 返回了无效的网络响应\(code)。请检查 HTTPS 服务或反向代理设置。"
        default:
            // Do not expose Foundation's description/userInfo: these may contain request URLs or credentials.
            return "NAS 网络请求失败\(code)。请检查连接地址与当前网络后重试。"
        }
    }
    return error.localizedDescription
}
