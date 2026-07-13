import Foundation

/// Identifiers shared by the app and the tunnel extension. Keep these in sync
/// with the entitlements and project.yml bundle IDs.
public enum BidichanConstants {
    public static let appGroup = "group.torkve.bidichan"
    public static let tunnelBundleID = "torkve.bidichan.tunnel"

    /// Keychain generic-password service under which per-profile PSKs are stored.
    public static let keychainService = "torkve.bidichan.psk"

    /// Keys in NETunnelProviderProtocol.providerConfiguration (non-secret only —
    /// the PSK is never placed here; it lives in the Keychain).
    public enum Key {
        public static let profileID = "profileID"
        public static let addr = "addr"
        public static let hostname = "hostname"
        public static let path = "path"
        public static let noTLSBinding = "noTLSBinding"
        public static let fingerprint = "fingerprint"
        public static let caCertPEM = "caCertPEM"
        public static let enableTUN = "enableTUN"
        public static let tunCIDR = "tunCIDR"
        public static let tunMTU = "tunMTU"
        public static let fullTunnel = "fullTunnel"
        public static let memoryLimitMB = "memoryLimitMB"
    }
}
