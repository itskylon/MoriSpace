import Foundation

/// Uses the same bundle localization as the system app and widget names.
enum AppBrand {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "MoriAppName") as? String ?? "Mori Space"
    }
}
