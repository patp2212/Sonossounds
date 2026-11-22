import Foundation

struct SoundSettings: Codable, Equatable {
    var volume: Int?, bass: Int?, treble: Int?, loudness: Bool?, sub: Int?, rear: Int?, rearMusic: Int?
    func clamped() -> SoundSettings {
        SoundSettings(volume: volume.map { clamp($0, 0, 100) }, bass: bass.map { clamp($0, -10, 10) }, treble: treble.map { clamp($0, -10, 10) },
                      loudness: loudness, sub: sub.map { clamp($0, -15, 15) }, rear: rear.map { clamp($0, -15, 15) }, rearMusic: rearMusic.map { clamp($0, -15, 15) })
    }
}

struct Preset: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var volume: Int?, bass: Int?, treble: Int?, loudness: Bool?, sub: Int?, rear: Int?, rearMusic: Int?
    var settings: SoundSettings { SoundSettings(volume: volume, bass: bass, treble: treble, loudness: loudness, sub: sub, rear: rear, rearMusic: rearMusic) }
    mutating func merge(_ s: SoundSettings) {
        if let v = s.volume { volume = v }
        if let v = s.bass { bass = v }
        if let v = s.treble { treble = v }
        if let v = s.loudness { loudness = v }
        if let v = s.sub { sub = v }
        if let v = s.rear { rear = v }
        if let v = s.rearMusic { rearMusic = v }
    }
}

/// Persistenz pro Gruppe (Schlüssel = Mitgliedernamen), gleiches Format wie presets.json der Webapp.
struct GroupEntry: Codable {
    var presets: [Preset]
    var active: String?
    var auto: [String: String]
    init(presets: [Preset] = defaultPresets(), active: String? = nil, auto: [String: String] = [:]) { self.presets = presets; self.active = active; self.auto = auto }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        presets = try c.decode([Preset].self, forKey: .presets)
        active = try c.decodeIfPresent(String.self, forKey: .active)
        auto = try c.decodeIfPresent([String: String].self, forKey: .auto) ?? [:]
    }
}

func defaultPresets() -> [Preset] {
    [Preset(id: "normal", name: "Normal", volume: 30, bass: 0, treble: 0, loudness: false),
     Preset(id: "bass", name: "Bass+", volume: 40, bass: 6, treble: 1, loudness: true),
     Preset(id: "nacht", name: "Nacht", volume: 12, bass: -3, treble: -1, loudness: false),
     Preset(id: "party", name: "Party", volume: 60, bass: 8, treble: 4, loudness: true)]
}

struct Current: Equatable { var volume: Int, bass: Int, treble: Int, loudness: Bool, sub: Int?, rear: Int?, rearMusic: Int?
    var settings: SoundSettings { SoundSettings(volume: volume, bass: bass, treble: treble, loudness: loudness, sub: sub, rear: rear, rearMusic: rearMusic) }
}
struct SourceInfo: Equatable { var type: String; var title: String? }

struct GroupInfo: Identifiable, Equatable {
    var key: String
    var name: String
    var members: [String]
    var grouped: Bool
    var current: Current
    var presets: [Preset]
    var active: String?
    var auto: [String: String]
    var source: SourceInfo?
    var id: String { key }
}

let autoSources: [(id: String, label: String)] = [("tv", "TV"), ("radio", "Radio"), ("spotify", "Spotify"), ("linein", "Line-in")]
func sourceLabel(_ s: SourceInfo?) -> String? {
    guard let s else { return nil }
    let base = ["tv": "TV", "radio": "Radio", "spotify": "Spotify", "linein": "Line-in"][s.type] ?? "Wiedergabe"
    return s.type == "radio" && s.title != nil ? "\(base) · \(s.title!)" : base
}
