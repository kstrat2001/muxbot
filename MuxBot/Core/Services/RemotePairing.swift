import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Pairing a device with darkmux on a Mac over the tailnet (darkmux #3560):
/// the Mac's tailnet address, the link a QR code carries, and the refusals
/// that pairing and its requests can get.
enum RemotePairing {
    /// The app's own link scheme: `muxbot://pair?url=<the Mac's address>`.
    static let scheme = "muxbot"

    /// The Mac's tailnet address, when `text` is one this app pairs with:
    /// HTTPS on a `*.ts.net` name, with no user or password in it. Anything
    /// else (a web page, plain http, another host) is refused, so a link
    /// never sends a pairing request somewhere else.
    static func address(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), host.hasSuffix(".ts.net"), host.count > ".ts.net".count,
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = "https"
        parts.host = host
        parts.query = nil
        parts.fragment = nil
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.url
    }

    /// The link a QR code on the Mac carries: the iPhone's camera opens
    /// Mux Bot with it, on its pairing screen.
    static func link(for mac: URL) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "url", value: mac.absoluteString)]
        return parts.url!
    }

    /// The Mac's address from a link this app opened or text you pasted:
    /// a `muxbot://pair` link, or the address itself.
    static func mac(from text: String) -> URL? {
        if let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           parts.scheme?.lowercased() == scheme {
            guard parts.host == "pair", let value = parts.queryItems?.first(where: { $0.name == "url" })?.value else { return nil }
            return address(value)
        }
        return address(text)
    }

    /// Answers worth asking again for: Tailscale on the Mac couldn't say
    /// who or which device is asking yet.
    static func isTransient(_ code: String?) -> Bool {
        code == "unavailable" || code == "remote_device_unknown"
    }

    /// A refusal about the tailnet, in plain words; nil for any other code.
    static func sentence(_ code: String?) -> String? {
        switch code {
        case "not_forwarded":
            String(localized: "darkmux on your Mac answers other devices only at its own tailnet address. Pair again from the address your Mac shows.")
        case "not_paired_remotely":
            String(localized: "This app was paired on the Mac itself, so that pairing works only there. Pair this device over your tailnet.")
        case "remote_user_not_owner":
            String(localized: "Only devices signed in to Tailscale as the Mac's own user can pair with it. Sign this device in to Tailscale as that user, then try again.")
        case "remote_identity_missing":
            String(localized: "Tailscale didn't say who this device belongs to (it may be signed in with a tag). Sign it in to Tailscale as yourself, then try again.")
        case "remote_identity_mismatch":
            String(localized: "This device is signed in to Tailscale as someone other than when it paired. Sign it in as that person again.")
        case "remote_identity_unconfirmed":
            String(localized: "Tailscale couldn't confirm who sent this. Make sure this device is signed in to Tailscale as you, then try again.")
        case "remote_device_unknown":
            String(localized: "Tailscale on your Mac couldn't tell which device this is. Try again in a moment.")
        case "remote_device_mismatch":
            String(localized: "This pairing belongs to another of your devices. Pair this one with your Mac too.")
        default: nil
        }
    }

    /// A QR code of `text`, sharp at any size (draw it without interpolation).
    static func qrCode(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// Where this Mac stands for pairing other devices, from `GET /client/whoami`
/// and gated on its `capabilities`.
enum RemoteAccess: Equatable {
    /// This darkmux can't say (it predates remote use): nothing is shown.
    case notSupported
    /// Remote use is off on this Mac.
    case off
    /// On the tailnet, but this darkmux can't pair other devices yet.
    case needsNewerDarkmux
    /// darkmux asked for the tailnet and couldn't get on it; why, for Show details.
    case unavailable(reason: String?)
    /// Other devices pair at this address.
    case available(URL)

    static func of(_ whoami: DarkmuxClient.Whoami) -> RemoteAccess {
        guard whoami.can("remote_tailscale") || whoami.can("remote_requests"), let remote = whoami.remote else { return .notSupported }
        switch remote.state {
        case "off": return .off
        case "available":
            guard whoami.can("remote_requests") else { return .needsNewerDarkmux }
            guard let url = remote.url.flatMap(RemotePairing.address) else { return .unavailable(reason: remote.url) }
            return .available(url)
        case "unavailable": return .unavailable(reason: remote.reason)
        default: return .notSupported
        }
    }
}
