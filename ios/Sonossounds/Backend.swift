import Foundation

protocol Backend: Sendable {
    func topology() async throws -> [ZoneGroup]
    func readSpeaker(_ m: Member) async throws -> SpeakerState
    func readGroupVolume(_ g: ZoneGroup) async throws -> Int
    func apply(_ g: ZoneGroup, _ s: SoundSettings) async throws
    func source(_ g: ZoneGroup) async throws -> RawSource
    func forget() async
}

actor LiveBackend: Backend {
    private var seedIp: String? = UserDefaults.standard.string(forKey: "seedIP")
    private let manualIp: String?
    private var lastDiscoveryFail: Date?
    init(manualIp: String?) { self.manualIp = (manualIp?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } }

    func forget() { seedIp = nil; lastDiscoveryFail = nil; UserDefaults.standard.removeObject(forKey: "seedIP") }

    func topology() async throws -> [ZoneGroup] {
        if let ip = manualIp { return try await getTopology(ip) }
        if let ip = seedIp {
            do { return try await getTopology(ip) } catch { seedIp = nil }
        }
        // Nach einem Fehlschlag nicht bei jedem Poll erneut 2,5 s suchen
        let fail = SonosError(message: "Keine Sonos-Lautsprecher gefunden. Bist du im selben WLAN und ist „Lokales Netzwerk“ für die App erlaubt? Alternativ unter ⚙︎ eine IP eintragen.")
        if let t = lastDiscoveryFail, Date().timeIntervalSince(t) < 10 { throw fail }
        for ip in await discoverBonjour() {
            if let t = try? await getTopology(ip) {
                seedIp = ip; lastDiscoveryFail = nil
                UserDefaults.standard.set(ip, forKey: "seedIP")
                return t
            }
        }
        lastDiscoveryFail = Date()
        throw fail
    }
    func readSpeaker(_ m: Member) async throws -> SpeakerState { try await Sonossounds.readSpeaker(m.ip, hasSub: m.hasSub, hasRears: m.hasRears) }
    func readGroupVolume(_ g: ZoneGroup) async throws -> Int { try await Sonossounds.readGroupVolume(g.coord.ip) }
    func apply(_ g: ZoneGroup, _ s: SoundSettings) async throws { try await applyToGroup(g, s) }
    func source(_ g: ZoneGroup) async throws -> RawSource { try await getSource(g.coord.ip) }
}

/// Simulierte Anlage für Demo/Simulator.
actor MockBackend: Backend {
    private let layout: [ZoneGroup] = {
        let m = [Member(id: "A", name: "Wohnzimmer", ip: "mock-0", hasSub: true, hasRears: true), Member(id: "B", name: "Küche", ip: "mock-1", hasSub: false, hasRears: false),
                 Member(id: "C", name: "Schlafzimmer", ip: "mock-2", hasSub: false, hasRears: false), Member(id: "D", name: "Terrasse", ip: "mock-3", hasSub: false, hasRears: false)]
        return [ZoneGroup(coordinator: "A", members: [m[0], m[1]]), ZoneGroup(coordinator: "C", members: [m[2]]), ZoneGroup(coordinator: "D", members: [m[3]])]
    }()
    private var state: [String: SpeakerState] = [
        "mock-0": .init(volume: 20, bass: 0, treble: 0, loudness: true, sub: 0, rear: 0, rearMusic: 0), "mock-1": .init(volume: 28, bass: 0, treble: 0, loudness: true),
        "mock-2": .init(volume: 36, bass: 0, treble: 0, loudness: true), "mock-3": .init(volume: 44, bass: 0, treble: 0, loudness: true)]
    func forget() {}
    func topology() -> [ZoneGroup] { layout }
    func readSpeaker(_ m: Member) -> SpeakerState { state[m.ip]! }
    func readGroupVolume(_ g: ZoneGroup) -> Int { g.members.map { state[$0.ip]!.volume }.reduce(0, +) / g.members.count }
    func apply(_ g: ZoneGroup, _ s: SoundSettings) {
        for m in g.members {
            if let v = s.volume { state[m.ip]!.volume = v }
            if let v = s.bass { state[m.ip]!.bass = v }
            if let v = s.treble { state[m.ip]!.treble = v }
            if let v = s.loudness { state[m.ip]!.loudness = v }
            if let v = s.sub, state[m.ip]!.sub != nil { state[m.ip]!.sub = v }
            if let v = s.rear, state[m.ip]!.rear != nil { state[m.ip]!.rear = v }
            if let v = s.rearMusic, state[m.ip]!.rearMusic != nil { state[m.ip]!.rearMusic = v }
        }
    }
    func source(_ g: ZoneGroup) -> RawSource { RawSource(uri: "x-sonosapi-stream:s1", state: "PLAYING", title: "Demo Radio") }
}
