import Foundation
import Bidichan
import BidichanKit

/// Turning a profile into a shareable link, and back.
///
/// The format itself lives in the Go core, which both this app and the Android
/// client embed — a link written by one has to be readable by the other, and
/// two hand-written implementations would drift the moment either gained a
/// field. This file only maps between `Profile` and that shared representation.
enum ProfileLinking {

    /// The prefix the app registers with the system, and matches before
    /// offering to import.
    static var prefix: String { MobileProfileLinkPrefix() }

    static func isProfileLink(_ url: URL) -> Bool {
        url.absoluteString.lowercased().hasPrefix(prefix.lowercased())
    }

    // MARK: - Sharing

    /// Renders a link for `profile`. `includeKey` decides whether the
    /// pre-shared key travels with it — see `LinkImport.carriesKey`.
    static func link(for profile: Profile, includeKey: Bool, psk: String?) throws -> String {
        guard let link = MobileNewProfileLink() else {
            throw LinkError.unavailable
        }
        link.name = profile.name
        link.addr = profile.serverAddress
        link.hostname = profile.hostname
        link.path = profile.path
        link.noTlsBinding = profile.noTLSBinding
        link.fingerprint = profile.fingerprint
        link.caCertPem = profile.caCertPEM
        link.enableTun = profile.enableTUN
        link.tunCidr = profile.tunCIDR
        link.tunCidr6 = profile.tunCIDR6
        link.tunMtu = profile.tunMTU
        link.fullTunnel = profile.fullTunnel
        link.memoryLimitMb = profile.memoryLimitMB
        link.resumeGraceSeconds = profile.resumeGraceSeconds
        link.channelsJson = encodeChannels(profile.channels)
        if includeKey, let psk, !psk.isEmpty {
            link.pskHex = psk
        }
        // gomobile hands back an explicit error pointer for a (string, error)
        // return rather than making it throw — same shape as GoBridge.control.
        var err: NSError?
        let encoded = link.encode(&err)
        if let err { throw err }
        return encoded
    }

    // MARK: - Importing

    /// A profile decoded from a link, held until the user accepts it.
    struct LinkImport {
        var profile: Profile
        var psk: String?
        var carriesKey: Bool { !(psk ?? "").isEmpty }
    }

    /// Decodes a link. The error carries the core's message, which is written
    /// to be shown as-is.
    static func decode(_ url: URL) throws -> LinkImport {
        var err: NSError?
        guard let link = MobileParseProfileLink(url.absoluteString, &err), err == nil else {
            throw err ?? LinkError.unreadable
        }
        // A fresh identifier: the link deliberately carries none, so importing
        // the same one twice adds a profile rather than overwriting one.
        var profile = Profile(id: UUID())
        profile.name = link.name.isEmpty ? "Imported profile" : link.name
        profile.serverAddress = link.addr
        profile.hostname = link.hostname
        profile.path = link.path
        profile.noTLSBinding = link.noTlsBinding
        profile.fingerprint = link.fingerprint.isEmpty ? "ios" : link.fingerprint
        profile.caCertPEM = link.caCertPem
        profile.enableTUN = link.enableTun
        profile.tunCIDR = link.tunCidr.isEmpty ? "10.42.0.2/24" : link.tunCidr
        profile.tunCIDR6 = link.tunCidr6
        profile.tunMTU = link.tunMtu > 0 ? link.tunMtu : 1400
        profile.fullTunnel = link.fullTunnel
        profile.memoryLimitMB = link.memoryLimitMb > 0 ? link.memoryLimitMb : 40
        profile.resumeGraceSeconds = link.resumeGraceSeconds > 0 ? link.resumeGraceSeconds : 90
        profile.channels = decodeChannels(link.channelsJson)
        return LinkImport(profile: profile, psk: link.pskHex.isEmpty ? nil : link.pskHex)
    }

    // MARK: - Channels

    /// The channel array as the shared format expects it. Identifiers are left
    /// out: they are local to a device, and the importing side makes its own.
    private static func encodeChannels(_ channels: [ChannelConfig]) -> String {
        let wire = channels.map {
            WireChannel(label: $0.label, kind: $0.kind.rawValue,
                        allInterfaces: $0.allInterfaces, port: $0.port,
                        target: $0.target, routeSystem: $0.routeSystem)
        }
        guard let data = try? JSONEncoder().encode(wire),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    private static func decodeChannels(_ json: String) -> [ChannelConfig] {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode([WireChannel].self, from: data) else { return [] }
        return wire.map { w in
            ChannelConfig(label: w.label,
                          kind: ChannelConfig.Kind(rawValue: w.kind) ?? .http,
                          allInterfaces: w.allInterfaces,
                          port: w.port,
                          target: w.target,
                          routeSystem: w.routeSystem)
        }
    }

    /// The channel as it travels. The core validates these same field names, so
    /// this must match what it expects.
    private struct WireChannel: Codable {
        var label: String = ""
        var kind: String
        var allInterfaces: Bool = false
        var port: Int
        var target: String = ""
        var routeSystem: Bool = false
    }

    enum LinkError: LocalizedError {
        case unavailable
        case unreadable
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Could not build a link."
            case .unreadable: return "That link could not be read."
            }
        }
    }
}
