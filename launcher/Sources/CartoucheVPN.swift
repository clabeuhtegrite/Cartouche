//
//  CartoucheVPN.swift
//  Cartouche
//
//  Whether LocalDevVPN is connected. The built-in SideStore reaches the
//  iPhone's own services through it when it signs in, renews Cartouche and
//  installs its updates. LocalDevVPN gives the iPhone a tunnel interface,
//  utun<n>, with an IPv4 address in 10.7.0.0/16: that is how SideStore's
//  own onboarding tells that it is on (OnboardingView.swift,
//  LocalDevVPNStep), and Cartouche reads the same, without connecting to
//  anything.
//
//  When what needs it starts with LocalDevVPN off, Cartouche has it
//  connect by itself (CartoucheVPNConnect): LocalDevVPN's own URL connects
//  it and opens Cartouche again, a second later.
//

import Foundation

enum CartoucheVPN {
    /// An interface of this device that is up, with its IPv4 address.
    struct Interface: Equatable {
        let name: String
        let address: String
    }

    /// Whether these interfaces hold LocalDevVPN's tunnel.
    static func hasTunnel(_ interfaces: [Interface]) -> Bool {
        interfaces.contains { $0.name.lowercased().hasPrefix("utun") && $0.address.hasPrefix("10.7.") }
    }

    /// Whether LocalDevVPN is connected now: in the gallery, as its scenario
    /// says, the simulator having the interfaces of the Mac under it.
    static var isConnected: Bool {
        #if CARTOUCHE_GALLERY
        return GalleryState.vpnConnected
        #else
        return hasTunnel(interfaces())
        #endif
    }

    /// This device's interfaces that are up, with their IPv4 addresses.
    static func interfaces() -> [Interface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var found: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, let address = entry.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            found.append(Interface(name: name, address: text))
        }
        return found
    }
}

/// When Cartouche has LocalDevVPN connect by itself, for what reaches this
/// iPhone through it: the sign-in, the registration of this iPhone, Renew
/// now, an update, and what Cartouche does by itself, the renewal in the
/// last days of its signature and the sign-in for a new certificate. Up to
/// 0.12.1, the player connected LocalDevVPN in its own app before each of
/// them, and came back. LocalDevVPN's URL localdevvpn://enable?scheme=NAME
/// connects it, then opens NAME:// a second later (LocalDevVPNApp.swift,
/// as SideStore's onboarding uses it): Cartouche comes back to the front,
/// and goes on as soon as the tunnel is up.
enum CartoucheVPNConnect {
    /// How long Cartouche waits for the tunnel once it has opened
    /// LocalDevVPN, counting only the time it is in front: LocalDevVPN
    /// opens Cartouche again a second after it starts connecting. The
    /// first time, iOS asks the player to allow LocalDevVPN's VPN
    /// configuration, in LocalDevVPN, which does not count.
    static let timeout: TimeInterval = 20
    /// How much a gap between two looks counts at most: iOS suspends
    /// Cartouche while LocalDevVPN is in front, and the look that follows
    /// counts as one.
    static let tick: TimeInterval = 1
    /// How long Cartouche waits, after it opened LocalDevVPN by itself,
    /// before it does again without the player: one that did not connect
    /// would not the next time Cartouche comes back either, and each time
    /// takes the player out of Cartouche for a moment. As long as the
    /// renewal waits between two tries (CartoucheAutomaticRenewal.spacing).
    static let automaticSpacing: TimeInterval = 6 * 3_600

    /// What Cartouche finds when something needs LocalDevVPN.
    struct Situation: Equatable {
        var connected: Bool
        /// Whether LocalDevVPN is on this iPhone.
        var installed: Bool
        /// Whether Cartouche is in front: iOS opens another app only from
        /// the one in front.
        var inFront: Bool
        /// Whether the player asked for what needs LocalDevVPN, with a
        /// tap: otherwise Cartouche started it by itself.
        var playerAsked: Bool
        /// Whether a game runs behind the console: LocalDevVPN in front
        /// would take it off the screen, and iOS ends the processes behind
        /// first.
        var gameRunning: Bool
        /// When Cartouche last opened LocalDevVPN by itself, without the
        /// player asking.
        var lastAutomaticOpen: Date?
    }

    enum Decision: Equatable {
        /// LocalDevVPN is connected: what needs it goes on at once.
        case goOn
        /// Cartouche opens LocalDevVPN, which connects and opens Cartouche
        /// again.
        case open
        /// Cartouche does not open it: LocalDevVPN is not on this iPhone,
        /// Cartouche is not in front, or, by itself, a game runs behind the
        /// console or it opened LocalDevVPN less than `automaticSpacing`
        /// ago. What needs it goes on as up to 0.12.1: the sign-in waits
        /// for the player to connect it, a renewal by itself waits for
        /// Cartouche to come back with it connected.
        case leave
    }

    /// What Cartouche does in SITUATION, at NOW. A last open dated after
    /// NOW, as when the iPhone's clock went back, holds nothing back.
    static func decide(_ situation: Situation, at now: Date) -> Decision {
        if situation.connected { return .goOn }
        guard situation.installed, situation.inFront else { return .leave }
        if !situation.playerAsked {
            if situation.gameRunning { return .leave }
            if let last = situation.lastAutomaticOpen, now >= last, now.timeIntervalSince(last) < automaticSpacing {
                return .leave
            }
        }
        return .open
    }

    /// LocalDevVPN's URL that connects it, then opens the app whose URL
    /// scheme is SCHEME: nil for a scheme LocalDevVPN could not open again.
    static func enableURL(returningTo scheme: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.")
        guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first),
              scheme.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        var components = URLComponents()
        components.scheme = "localdevvpn"
        components.host = "enable"
        components.queryItems = [URLQueryItem(name: "scheme", value: scheme)]
        return components.url
    }

    /// The wait for the tunnel once Cartouche has opened LocalDevVPN.
    struct Wait: Equatable {
        enum Next: Equatable {
            /// LocalDevVPN is connected: what waited goes on.
            case goOn
            case keepWaiting
            /// Its limit went by in front, without the tunnel.
            case stop
        }

        /// How long Cartouche has waited in front.
        private(set) var waited: TimeInterval = 0
        private var last: Date
        /// How long it waits in front at most: `timeout`, shorter in the
        /// launcher's harness.
        let limit: TimeInterval

        init(started: Date, limit: TimeInterval = CartoucheVPNConnect.timeout) {
            last = started
            self.limit = limit
        }

        /// Cartouche looks, LocalDevVPN being CONNECTED or not, Cartouche
        /// IN FRONT or not, at NOW.
        mutating func next(connected: Bool, inFront: Bool, at now: Date) -> Next {
            if connected { return .goOn }
            let gap = now.timeIntervalSince(last)
            last = now
            if inFront { waited += min(max(0, gap), CartoucheVPNConnect.tick) }
            return waited >= limit ? .stop : .keepWaiting
        }

        /// How long it waited in front, in whole seconds, for the
        /// measurements.
        var seconds: Double { waited.rounded() }
    }
}
