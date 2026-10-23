import Foundation

public struct NetworkSocket: Identifiable, Equatable {
    public let id: String
    public let process: String
    public let pid: Int
    public let transport: String
    public let local: String
    public let remote: String?
    public let state: String
    /// "IPv4" or "IPv6" as reported by lsof; empty when not reported.
    public var family = ""
    public init(id: String, process: String, pid: Int, transport: String, local: String, remote: String?, state: String, family: String = "") {
        self.id = id; self.process = process; self.pid = pid; self.transport = transport; self.local = local; self.remote = remote; self.state = state; self.family = family
    }
    public var localHost: String { NetworkSockets.split(local).host }
    public var localPort: String { NetworkSockets.split(local).port }
    public var remoteHost: String? { remote.map { NetworkSockets.split($0).host } }
    public var scope: String {
        let host = localHost
        if host == "::1" || host.hasPrefix("127.") { return "This Mac only" }
        if host == "*" || host == "::" || host == "0.0.0.0" { return "All interfaces" }
        return "Specific interface"
    }
    /// Familiar process names describe a usual role, never a verified identity.
    public var role: String? {
        switch process.lowercased() {
        case "postgres": return "PostgreSQL database"
        case "redis-server": return "Redis database"
        case "node": return "Node.js process"
        case "controlcenter": return "macOS Control Center"
        case "rapportd", "sharingd": return "macOS service"
        default: return nil
        }
    }
    public var context: String {
        [role, listening ? scope : remote == nil ? "Bound socket" : "Remote connection"].compactMap { $0 }.joined(separator: " · ")
    }
    /// Address class of the remote end. Private ranges are labelled as the local network; nothing is resolved or looked up.
    public var destination: String? { remoteHost.map(NetworkSockets.addressClass) }
    public var explanation: String {
        "The process name is reported by macOS. A familiar process name describes its usual role, not a verified app identity. Loopback listeners accept connections on this Mac only; all-interface listeners bind across interfaces. Firewall rules and network routing still determine reachability. Strand does not inspect packet contents or identify a service from its port number."
    }
    public var listening: Bool { state == "LISTEN" }
    /// UDP sockets bound to a port without a fixed peer. They receive datagrams but are not TCP listeners.
    public var udpBound: Bool { transport == "UDP" && remote == nil && localPort != "*" }
}

/// Sockets that differ only by address family, file descriptor or helper process are shown once.
public struct SocketEntry: Identifiable, Equatable {
    public let id: String
    public let transport: String
    public let local: String
    public let remote: String?
    public let state: String
    public let families: [String]
    public let count: Int
    /// Every process holding one of the merged sockets.
    public let pids: [Int]
    public let sample: NetworkSocket
    /// Copies beyond one per address family, such as the same port held by several helper processes.
    public var duplicates: Int { count / max(1, families.count) }
}

public struct SocketGroup: Identifiable, Equatable {
    public let process: String
    public let pids: [Int]
    public let entries: [SocketEntry]
    public var id: String { process }
    public var role: String? { entries.first?.sample.role }
    public var socketCount: Int { entries.reduce(0) { $0 + $1.count } }
}

public enum NetworkSockets {
    /// lsof's field format avoids whitespace ambiguities in process names and IPv6 addresses.
    public static func parse(_ text: String) -> [NetworkSocket] {
        var pid = 0, process = "", descriptor = "", transport = "", endpoint = "", state = "", family = ""
        var result: [NetworkSocket] = []
        func flush() {
            guard !endpoint.isEmpty, !transport.isEmpty else { return }
            let endpoints = endpoint.components(separatedBy: "->")
            result.append(NetworkSocket(id: "\(pid):\(descriptor):\(transport):\(endpoint)", process: process, pid: pid, transport: transport, local: endpoints[0], remote: endpoints.count > 1 ? endpoints[1] : nil, state: state.isEmpty ? "Bound" : state, family: family))
        }
        for line in text.split(separator: "\n").map(String.init) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p": flush(); pid = Int(value) ?? 0; descriptor = ""; transport = ""; endpoint = ""; state = ""; family = ""
            case "c": process = value
            case "f": flush(); descriptor = value; transport = ""; endpoint = ""; state = ""; family = ""
            case "t": family = value
            case "P": transport = value
            case "n": endpoint = value
            case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return result.sorted { ($0.process, $0.local, $0.id) < ($1.process, $1.local, $1.id) }
    }

    /// Splits at the last colon; lsof brackets IPv6 hosts.
    public static func split(_ endpoint: String) -> (host: String, port: String) {
        guard let colon = endpoint.lastIndex(of: ":") else { return (endpoint, "") }
        var host = String(endpoint[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host, String(endpoint[endpoint.index(after: colon)...]))
    }

    public static func addressClass(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("::ffff:") { value = String(value.dropFirst(7)) }
        if value == "::1" || value.hasPrefix("127.") { return "This Mac" }
        let octets = value.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            if octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 169 && octets[1] == 254) { return "Local network" }
            return "Public address"
        }
        if value.hasPrefix("fe80") || value.hasPrefix("fc") || value.hasPrefix("fd") { return "Local network" }
        return "Public address"
    }

    /// Groups by process name and merges sockets with identical endpoints and state.
    public static func grouped(_ sockets: [NetworkSocket], byCount: Bool = false) -> [SocketGroup] {
        let groups = Dictionary(grouping: sockets, by: \.process).map { process, members -> SocketGroup in
            // Loopback and wildcard bindings differ between IPv4 and IPv6 (127.0.0.1 and ::1), so unconnected sockets merge by scope.
            let merged = Dictionary(grouping: members) { socket in
                let local = socket.remote == nil && socket.scope != "Specific interface" ? socket.scope + ":" + socket.localPort : socket.local
                return [socket.transport, local, socket.remote ?? "", socket.state].joined(separator: "|")
            }
            let entries = merged.map { key, same -> SocketEntry in
                let first = same[0]
                let families = Set(same.map(\.family).filter { !$0.isEmpty }).sorted()
                return SocketEntry(id: process + "|" + key, transport: first.transport, local: first.local, remote: first.remote, state: first.state, families: families, count: same.count, pids: Set(same.map(\.pid)).sorted(), sample: first)
            }.sorted { a, b in
                let left = (Int(a.sample.localPort) ?? .max, a.remote ?? "", a.local), right = (Int(b.sample.localPort) ?? .max, b.remote ?? "", b.local)
                return a.remote == nil ? left < right : (a.remote ?? "", a.local) < (b.remote ?? "", b.local)
            }
            return SocketGroup(process: process, pids: Set(members.map(\.pid)).sorted(), entries: entries)
        }
        return groups.sorted { a, b in
            if byCount, a.entries.count != b.entries.count { return a.entries.count > b.entries.count }
            return a.process.localizedCaseInsensitiveCompare(b.process) == .orderedAscending
        }
    }
}
