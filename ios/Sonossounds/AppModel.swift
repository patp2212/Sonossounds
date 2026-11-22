import Foundation
import Observation

@MainActor @Observable
final class AppModel {
    var groups: [GroupInfo] = []
    var loading = true
    var error: String?
    var toast: String?
    var demo: Bool = UserDefaults.standard.bool(forKey: "demo") { didSet { UserDefaults.standard.set(demo, forKey: "demo"); resetBackend() } }
    var manualIP: String = UserDefaults.standard.string(forKey: "manualIP") ?? "" { didSet { UserDefaults.standard.set(manualIP, forKey: "manualIP") } }
    /// Solange der Nutzer an einem Regler zieht, wird nicht im Hintergrund neu geladen.
    var interacting = false

    private var backend: Backend
    private var store: [String: GroupEntry] = [:]
    private var busy = false
    private var loop: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private static let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }()

    init() {
        let d = UserDefaults.standard
        backend = d.bool(forKey: "demo") ? MockBackend() : LiveBackend(manualIp: d.string(forKey: "manualIP"))
        if let data = try? Data(contentsOf: Self.storeURL), let s = try? JSONDecoder().decode([String: GroupEntry].self, from: data) { store = s }
    }

    // MARK: Lebenszyklus
    func resetBackend() {
        backend = demo ? MockBackend() : LiveBackend(manualIp: manualIP)
        sources = [:]; groups = []; loading = true
        Task { await load() }
    }
    func rescan() async { await backend.forget(); resetBackend() }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.load()
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.pollSources()
                if tick % 2 == 1 { await self.silentRefresh() }
                tick += 1
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }

    // MARK: Laden
    func load() async {
        if busy { return }
        busy = true; defer { busy = false }
        do { groups = try await describe(); error = nil } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func silentRefresh() async {
        if busy || interacting { return }
        busy = true; defer { busy = false }
        if let g = try? await describe(), g != groups, !interacting { groups = g; error = nil }
    }

    private func entry(_ key: String) -> GroupEntry { store[key] ?? GroupEntry() }
    private func mutate(_ key: String, _ f: (inout GroupEntry) -> Void) {
        var e = entry(key); f(&e); store[key] = e
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: Self.storeURL, options: .atomic) }
    }

    private func describe() async throws -> [GroupInfo] {
        let b = backend
        let zones = try await b.topology()
        var out: [(Int, GroupInfo)] = []
        try await withThrowingTaskGroup(of: (Int, GroupInfo).self) { tg in
            for (i, g) in zones.enumerated() {
                tg.addTask {
                    let states = try await withThrowingTaskGroup(of: (Int, SpeakerState).self) { s in
                        for (j, m) in g.members.enumerated() { s.addTask { (j, try await b.readSpeaker(m)) } }
                        var r: [(Int, SpeakerState)] = []
                        for try await x in s { r.append(x) }
                        return r.sorted { $0.0 < $1.0 }.map(\.1)
                    }
                    let coord = states[max(0, g.members.firstIndex { $0.id == g.coordinator } ?? 0)]
                    let vol = try await b.readGroupVolume(g)
                    return (i, await self.info(g, states, coord, vol))
                }
            }
            for try await x in tg { out.append(x) }
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
    private func info(_ g: ZoneGroup, _ states: [SpeakerState], _ coord: SpeakerState, _ vol: Int) -> GroupInfo {
        let key = g.key, e = entry(key), src = sources[key]
        return GroupInfo(key: key, name: g.members.map(\.name).joined(separator: " + "), members: g.members.map(\.name), grouped: g.members.count > 1,
                         current: Current(volume: vol, bass: coord.bass, treble: coord.treble, loudness: coord.loudness, sub: states.compactMap(\.sub).first,
                                           rear: states.compactMap(\.rear).first, rearMusic: states.compactMap(\.rearMusic).first),
                         presets: e.presets, active: e.active, auto: e.auto, source: src?.now.map { SourceInfo(type: $0, title: src?.title) })
    }

    // MARK: Aktionen
    func showToast(_ m: String) {
        toast = m; toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { toast = nil } }
    }
    private func guarded(_ f: () async throws -> Void) async { do { try await f() } catch { showToast(error.localizedDescription) } }
    private func findGroup(_ key: String) async throws -> ZoneGroup {
        guard let g = try await backend.topology().first(where: { $0.key == key }) else { throw SonosError(message: "Gruppe nicht gefunden (Gruppierung geändert?)") }
        return g
    }
    private func setActive(_ key: String, _ id: String?) {
        mutate(key) { $0.active = id }
        if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].active = id }
    }

    /// Manuelle Einstellung (Regler) – hebt das aktive Preset auf
    func applyManual(_ key: String, _ s: SoundSettings) async {
        await guarded { try await backend.apply(try await findGroup(key), s.clamped()); setActive(key, nil) }
    }
    func applyPreset(_ key: String, _ id: String) async {
        await guarded {
            guard let p = entry(key).presets.first(where: { $0.id == id }) else { throw SonosError(message: "Preset nicht gefunden") }
            try await backend.apply(try await findGroup(key), p.settings.clamped()); setActive(key, id)
        }
        await load()
    }
    func updatePreset(_ key: String, _ id: String, _ s: SoundSettings) async {
        await guarded { mutate(key) { e in if let i = e.presets.firstIndex(where: { $0.id == id }) { e.presets[i].merge(s.clamped()); e.active = id } } }
        await load()
    }
    func savePreset(_ key: String, name: String, _ s: SoundSettings) async {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard !name.isEmpty else { return showToast("Name fehlt") }
        var p = Preset(id: String(Int(Date().timeIntervalSince1970 * 1000), radix: 36), name: name); p.merge(s.clamped())
        mutate(key) { $0.presets.append(p); $0.active = p.id }
        await load()
    }
    func deletePreset(_ key: String, _ id: String) async {
        mutate(key) { e in
            e.presets.removeAll { $0.id == id }
            e.auto = e.auto.filter { $0.value != id }
            if e.active == id { e.active = nil }
        }
        await load()
    }
    func setAuto(_ key: String, source: String, presetId: String?) {
        mutate(key) { if let p = presetId { $0.auto[source] = p } else { $0.auto.removeValue(forKey: source) } }
        if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].auto = entry(key).auto }
    }

    // MARK: Quellen-Automatik (läuft nur, solange die App im Vordergrund ist)
    private struct Src { var type: String?; var now: String?; var title: String?; var cand = 0; var idleSince: Date? }
    private var sources: [String: Src] = [:]
    private let idleSeconds: TimeInterval = 600

    private func pollSources() async {
        guard let zones = try? await backend.topology() else { return }
        for g in zones {
            let key = g.key
            guard let raw = try? await backend.source(g) else { continue }
            let now = raw.state == "PLAYING" ? classifySource(raw.uri) : nil
            guard var st = sources[key] else { sources[key] = Src(type: now, now: now, title: raw.title); continue } // erste Messung = Ausgangszustand
            st.now = now; st.title = raw.title
            if now == nil { st.idleSince = st.idleSince ?? Date(); st.cand = 0; sources[key] = st; continue }
            let changed = st.type != now || (st.idleSince.map { Date().timeIntervalSince($0) > idleSeconds } ?? false)
            if !changed { st.idleSince = nil; st.cand = 0; sources[key] = st; continue }
            st.cand += 1
            if st.cand < 2 { sources[key] = st; continue } // 2 Messungen in Folge: kurzes Flackern ignorieren
            st.type = now; st.idleSince = nil; st.cand = 0; sources[key] = st
            if let now, let p = entry(key).presets.first(where: { $0.id == entry(key).auto[now] }) {
                do { try await backend.apply(g, p.settings.clamped()); setActive(key, p.id); await silentRefresh() }
                catch { showToast("Automatik fehlgeschlagen: \(error.localizedDescription)") }
            }
        }
    }
}
