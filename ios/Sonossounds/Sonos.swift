// Minimaler Sonos-Client über das lokale UPnP/SOAP-Protokoll (Port 1400). Port von sonos.js.
import Foundation
import Network

struct Svc { let path: String; let urn: String }
enum Sv {
    static let rc = Svc(path: "/MediaRenderer/RenderingControl/Control", urn: "urn:schemas-upnp-org:service:RenderingControl:1")
    static let grc = Svc(path: "/MediaRenderer/GroupRenderingControl/Control", urn: "urn:schemas-upnp-org:service:GroupRenderingControl:1")
    static let zgt = Svc(path: "/ZoneGroupTopology/Control", urn: "urn:schemas-upnp-org:service:ZoneGroupTopology:1")
    static let avt = Svc(path: "/MediaRenderer/AVTransport/Control", urn: "urn:schemas-upnp-org:service:AVTransport:1")
}

struct SonosError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Member: Hashable { var id: String; var name: String; var ip: String; var hasSub: Bool; var hasRears: Bool }
struct ZoneGroup {
    var coordinator: String
    var members: [Member]
    var coord: Member { members.first { $0.id == coordinator } ?? members[0] }
    var key: String { members.map(\.name).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.joined(separator: " + ") }
}
struct SpeakerState { var volume: Int; var bass: Int; var treble: Int; var loudness: Bool; var sub: Int?; var rear: Int?; var rearMusic: Int? }
struct RawSource { var uri: String; var state: String; var title: String? }

func esc(_ s: String) -> String {
    var out = ""
    for c in s {
        switch c {
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "&": out += "&amp;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        default: out.append(c)
        }
    }
    return out
}
func unesc(_ s: String) -> String {
    s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
}
func tag(_ xml: String, _ name: String) -> String? {
    guard let a = xml.range(of: "<\(name)>"), let b = xml.range(of: "</\(name)>", range: a.upperBound..<xml.endIndex) else { return nil }
    return String(xml[a.upperBound..<b.lowerBound])
}
func regexMatches(_ pattern: String, _ s: String) -> [[String]] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
}
func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(hi, max(lo, v)) }

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 4
    c.waitsForConnectivity = false
    return URLSession(configuration: c)
}()

func soap(_ ip: String, _ svc: Svc, _ action: String, _ args: [(String, String)] = []) async throws -> String {
    let body = args.map { "<\($0.0)>\(esc($0.1))</\($0.0)>" }.joined()
    let xml = #"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\#(action) xmlns:u="\#(svc.urn)">\#(body)</u:\#(action)></s:Body></s:Envelope>"#
    guard let url = URL(string: "http://\(ip):1400\(svc.path)") else { throw SonosError(message: "Ungültige Adresse \(ip)") }
    var req = URLRequest(url: url, timeoutInterval: 4)
    req.httpMethod = "POST"
    req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
    req.setValue("\"\(svc.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
    req.httpBody = Data(xml.utf8)
    let (data, resp) = try await session.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw SonosError(message: "Sonos \(action) fehlgeschlagen (\(status)) auf \(ip)") }
    return String(decoding: data, as: UTF8.self)
}

func parseTopology(_ zoneGroupStateXml: String) -> [ZoneGroup] {
    let xml = unesc(zoneGroupStateXml)
    func attr(_ n: String, _ s: String) -> String? { regexMatches("\\b\(n)=\"([^\"]*)\"", s).first?[1] }
    var groups: [ZoneGroup] = []
    for g in regexMatches(#"<ZoneGroup\s+([^>]*)>([\s\S]*?)</ZoneGroup>"#, xml) {
        let coordinator = attr("Coordinator", g[1]) ?? ""
        var members: [Member] = []
        for m in regexMatches(#"<ZoneGroupMember\s+([^>]*?)/?>"#, g[2]) {
            if attr("Invisible", m[1]) == "1" { continue } // Subs / Surround-Satelliten
            guard let loc = attr("Location", m[1]), let ip = regexMatches(#"//([^:/]+)"#, loc).first?[1] else { continue }
            // Sub/Rears im Home-Theater-Verbund: die Pegel (SubGain, SurroundLevel, MusicSurroundLevel) liegen auf dem Hauptgerät
            let map = attr("HTSatChanMapSet", m[1]) ?? ""
            let hasSub = !regexMatches(#":SW\b"#, map).isEmpty, hasRears = !regexMatches(#":(LR|RR)\b"#, map).isEmpty
            members.append(Member(id: attr("UUID", m[1]) ?? ip, name: unesc(attr("ZoneName", m[1]) ?? "?"), ip: ip, hasSub: hasSub, hasRears: hasRears))
        }
        if !members.isEmpty { groups.append(ZoneGroup(coordinator: coordinator, members: members)) }
    }
    return groups
}

func getTopology(_ anyIp: String) async throws -> [ZoneGroup] {
    parseTopology(tag(try await soap(anyIp, Sv.zgt, "GetZoneGroupState"), "ZoneGroupState") ?? "")
}

private let inst: [(String, String)] = [("InstanceID", "0")]

private func num(_ ip: String, _ action: String, _ extra: [(String, String)] = []) async throws -> Int {
    let xml = try await soap(ip, Sv.rc, action, inst + extra)
    return Int(tag(xml, "Current" + action.dropFirst(3)) ?? "") ?? 0
}
func readEQ(_ ip: String, _ type: String) async throws -> Int {
    Int(tag(try await soap(ip, Sv.rc, "GetEQ", inst + [("EQType", type)]), "CurrentValue") ?? "") ?? 0
}
func readSpeaker(_ ip: String, hasSub: Bool, hasRears: Bool = false) async throws -> SpeakerState {
    async let v = num(ip, "GetVolume", [("Channel", "Master")])
    async let b = num(ip, "GetBass")
    async let t = num(ip, "GetTreble")
    async let l = num(ip, "GetLoudness", [("Channel", "Master")])
    let (volume, bass, treble, loud) = try await (v, b, t, l)
    let sub = hasSub ? try? await readEQ(ip, "SubGain") : nil
    var rear: Int?, rearMusic: Int?
    if hasRears, let r = try? await readEQ(ip, "SurroundLevel"), let rm = try? await readEQ(ip, "MusicSurroundLevel") { rear = r; rearMusic = rm }
    return SpeakerState(volume: volume, bass: bass, treble: treble, loudness: loud != 0, sub: sub, rear: rear, rearMusic: rearMusic)
}
/// Aktuelle Quelle eines Koordinators: URI, Transportzustand, Titel (bei Radio der Sendername).
func getSource(_ ip: String) async throws -> RawSource {
    async let m = soap(ip, Sv.avt, "GetMediaInfo", inst)
    async let t = soap(ip, Sv.avt, "GetTransportInfo", inst)
    let (media, tr) = try await (m, t)
    let title = regexMatches(#"<dc:title>([^<]*)"#, unesc(tag(media, "CurrentURIMetaData") ?? "")).first?[1]
    return RawSource(uri: unesc(tag(media, "CurrentURI") ?? ""), state: tag(tr, "CurrentTransportState") ?? "", title: title.map(unesc))
}
/// URI -> tv | spotify | linein | radio | other (nil = nichts eingestellt)
func classifySource(_ uri: String) -> String? {
    if uri.isEmpty { return nil }
    if uri.hasPrefix("x-sonos-htastream:") { return "tv" }
    if uri.localizedCaseInsensitiveContains("spotify") { return "spotify" }
    if uri.hasPrefix("x-rincon-stream:") { return "linein" }
    if !regexMatches(#"^(x-sonosapi-(stream|radio|hls)|aac|hls-radio|x-rincon-mp3radio):"#, uri).isEmpty { return "radio" }
    return "other"
}
func readGroupVolume(_ coordIp: String) async throws -> Int {
    Int(tag(try await soap(coordIp, Sv.grc, "GetGroupVolume", inst), "CurrentVolume") ?? "") ?? 0
}
func applyToGroup(_ group: ZoneGroup, _ s: SoundSettings) async throws {
    var jobs: [() async throws -> Void] = []
    if let v = s.volume { jobs.append { _ = try await soap(group.coord.ip, Sv.grc, "SetGroupVolume", inst + [("DesiredVolume", "\(clamp(v, 0, 100))")]) } }
    for m in group.members {
        if let b = s.bass { jobs.append { _ = try await soap(m.ip, Sv.rc, "SetBass", inst + [("DesiredBass", "\(clamp(b, -10, 10))")]) } }
        if let t = s.treble { jobs.append { _ = try await soap(m.ip, Sv.rc, "SetTreble", inst + [("DesiredTreble", "\(clamp(t, -10, 10))")]) } }
        if let sub = s.sub, m.hasSub { jobs.append { _ = try await soap(m.ip, Sv.rc, "SetEQ", inst + [("EQType", "SubGain"), ("DesiredValue", "\(clamp(sub, -15, 15))")]) } }
        if let r = s.rear, m.hasRears { jobs.append { _ = try await soap(m.ip, Sv.rc, "SetEQ", inst + [("EQType", "SurroundLevel"), ("DesiredValue", "\(clamp(r, -15, 15))")]) } }
        if let r = s.rearMusic, m.hasRears { jobs.append { _ = try await soap(m.ip, Sv.rc, "SetEQ", inst + [("EQType", "MusicSurroundLevel"), ("DesiredValue", "\(clamp(r, -15, 15))")]) } }
        if let l = s.loudness { jobs.append { _ = try await soap(m.ip, Sv.rc, "SetLoudness", inst + [("Channel", "Master"), ("DesiredLoudness", l ? "1" : "0")]) } }
    }
    try await withThrowingTaskGroup(of: Void.self) { tg in
        for j in jobs { tg.addTask { try await j() } }
        try await tg.waitForAll()
    }
}

// ── Erkennung per Bonjour (_sonos._tcp). SSDP-Multicast bräuchte auf iOS ein Apple-Spezial-Entitlement. ──
func discoverBonjour(timeout: TimeInterval = 2.5) async -> [String] {
    await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
        let q = DispatchQueue(label: "sonos.discover")
        let browser = NWBrowser(for: .bonjour(type: "_sonos._tcp", domain: nil), using: .tcp)
        var found = Set<String>(), done = false, conns: [NWConnection] = []
        browser.browseResultsChangedHandler = { results, _ in
            for r in results {
                let params = NWParameters.tcp
                (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
                let c = NWConnection(to: r.endpoint, using: params)
                c.stateUpdateHandler = { state in
                    guard case .ready = state else { return }
                    if case let .hostPort(host, _)? = c.currentPath?.remoteEndpoint, case let .ipv4(a) = host {
                        found.insert(a.rawValue.map(String.init).joined(separator: "."))
                    }
                    c.cancel()
                }
                conns.append(c)
                c.start(queue: q)
            }
        }
        browser.start(queue: q)
        q.asyncAfter(deadline: .now() + timeout) {
            guard !done else { return }
            done = true
            browser.cancel(); conns.forEach { $0.cancel() }
            cont.resume(returning: Array(found))
        }
    }
}
