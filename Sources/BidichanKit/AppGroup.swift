import Foundation

/// Access to the shared App Group container, used to persist the profile list
/// so both the app and the extension see the same data.
public enum AppGroup {
    public static var containerURL: URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: BidichanConstants.appGroup) else {
            fatalError("App Group \(BidichanConstants.appGroup) is not configured in entitlements")
        }
        return url
    }

    public static var defaults: UserDefaults {
        guard let d = UserDefaults(suiteName: BidichanConstants.appGroup) else {
            fatalError("cannot open shared UserDefaults for \(BidichanConstants.appGroup)")
        }
        return d
    }
}
