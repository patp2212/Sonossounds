import SwiftUI

extension Color {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.063)
    static let card = Color(red: 0.078, green: 0.078, blue: 0.11)
    static let line = Color(red: 0.141, green: 0.141, blue: 0.2)
    static let mute = Color(red: 0.545, green: 0.545, blue: 0.627)
    static let accentA = Color(red: 0.486, green: 0.361, blue: 1)
    static let accentB = Color(red: 0.133, green: 0.827, blue: 0.933)
    static let chip = Color(red: 0.106, green: 0.106, blue: 0.153)
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            RadialGradient(colors: [Color(red: 0.11, green: 0.08, blue: 0.25), .clear], center: .topLeading, startRadius: 0, endRadius: 520).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if model.loading { Text("Suche Lautsprecher …").msg() }
                    else if let e = model.error, model.groups.isEmpty { Text(e).msg() }
                    else if model.groups.isEmpty { Text("Keine Gruppen gefunden.").msg() }
                    ForEach(model.groups) { g in GroupCard(model: model, group: g) }
                }
                .frame(maxWidth: 640).padding(.horizontal, 16).padding(.bottom, 60)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.load() }
            if let t = model.toast {
                VStack { Spacer(); Text(t).font(.subheadline).padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Color(red: 0.9, green: 0.28, blue: 0.3), in: Capsule()).padding(.bottom, 24) }
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.toast)
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
    }

    private var header: some View {
        HStack {
            Text("Sonossounds").font(.system(size: 28, weight: .bold)).tracking(-0.8)
            Spacer()
            if model.demo { Text("Demo").font(.caption).foregroundStyle(Color.accentB).padding(.horizontal, 10).padding(.vertical, 2)
                .overlay(Capsule().stroke(Color.accentB)) }
            roundButton("arrow.clockwise") { Task { await model.load() } }
            roundButton("gearshape") { showSettings = true }
        }
        .padding(.top, 8).padding(.horizontal, 4)
    }
    private func roundButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 40, height: 40).background(Color.card, in: Circle()).overlay(Circle().stroke(Color.line))
        }.buttonStyle(.plain)
    }
}

extension Text { func msg() -> some View { self.foregroundStyle(Color.mute).multilineTextAlignment(.center).padding(40).frame(maxWidth: .infinity) } }

struct GroupCard: View {
    let model: AppModel
    let group: GroupInfo
    @State private var cur: Current
    @State private var sendTask: Task<Void, Never>?
    @State private var dragging = 0
    @State private var overwrite: Preset?
    @State private var naming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    init(model: AppModel, group: GroupInfo) { self.model = model; self.group = group; _cur = State(initialValue: group.current) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.name).font(.title3.weight(.semibold))
            Text([group.grouped ? "Gruppe · \(group.members.count) Lautsprecher" : "Einzelner Lautsprecher", sourceLabel(group.source)].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(Color.mute).padding(.top, 2).padding(.bottom, 16)
            chips
            slider("Lautstärke", 0, 100, \.volume)
            slider("Bass", -10, 10, \.bass)
            slider("Höhen", -10, 10, \.treble)
            if cur.sub != nil { sliderOpt("Sub", -15, 15, \.sub) }
            if cur.rear != nil { sliderOpt("Rears TV", -15, 15, \.rear); sliderOpt("Rears Musik", -15, 15, \.rearMusic) }
            Toggle("Loudness", isOn: Binding(get: { cur.loudness }, set: { cur.loudness = $0; scheduleSend() }))
                .tint(.accentA).foregroundStyle(Color.mute).font(.subheadline).padding(.top, 14)
            DisclosureGroup("Automatik nach Quelle") {
                ForEach(autoSources, id: \.id) { s in
                    HStack {
                        Text(s.label)
                        Spacer()
                        Picker(s.label, selection: Binding(get: { group.auto[s.id] ?? "" }, set: { model.setAuto(group.key, source: s.id, presetId: $0.isEmpty ? nil : $0) })) {
                            Text("aus").tag("")
                            ForEach(group.presets) { Text($0.name).tag($0.id) }
                        }.pickerStyle(.menu).tint(.white)
                    }.padding(.vertical, 2)
                }
            }
            .font(.subheadline).foregroundStyle(Color.mute).tint(Color.mute).padding(.top, 14)
            if let a = group.presets.first(where: { $0.id == group.active }) {
                Button("Preset „\(a.name)“ löschen") { confirmDelete = true }
                    .font(.footnote).foregroundStyle(Color.mute).padding(.top, 10)
                    .confirmationDialog("„\(a.name)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Löschen", role: .destructive) { Task { await model.deletePreset(group.key, a.id) } }
                    }
            }
        }
        .padding(20)
        .background(LinearGradient(colors: [Color(red: 0.09, green: 0.09, blue: 0.135), .card], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.line))
        .onChange(of: group.current) { _, new in if dragging == 0 { cur = new } }
        .alert("Neues Preset für „\(group.name)“", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Speichern") { let n = newName; Task { await model.savePreset(group.key, name: n, cur.settings) } }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Preset „\(overwrite?.name ?? "")“ mit den aktuellen Werten überschreiben?", isPresented: Binding(get: { overwrite != nil }, set: { if !$0 { overwrite = nil } }), titleVisibility: .visible) {
            Button("Überschreiben") { if let p = overwrite { Task { await model.updatePreset(group.key, p.id, cur.settings) } } }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(group.presets) { p in
                    let on = group.active == p.id
                    Text(p.name).padding(.horizontal, 16).padding(.vertical, 10)
                        .foregroundStyle(on ? .white : Color.mute)
                        .background { if on { Capsule().fill(LinearGradient(colors: [.accentA, .accentB], startPoint: .topLeading, endPoint: .bottomTrailing)).shadow(color: Color.accentA.opacity(0.35), radius: 10, y: 4) }
                                      else { Capsule().fill(Color.chip).overlay(Capsule().stroke(Color.line)) } }
                        .contentShape(Capsule())
                        // Kurzer Tipp = anwenden, langer Druck (0,6 s) = mit aktuellen Reglerwerten überschreiben
                        .onTapGesture { Task { await model.applyPreset(group.key, p.id) } }
                        .onLongPressGesture(minimumDuration: 0.6) { UIImpactFeedbackGenerator(style: .medium).impactOccurred(); overwrite = p }
                }
                Button { newName = ""; naming = true } label: {
                    Text("+ Speichern").padding(.horizontal, 16).padding(.vertical, 10).foregroundStyle(Color.mute)
                        .background(Capsule().fill(Color.chip)).overlay(Capsule().strokeBorder(Color.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }.buttonStyle(.plain)
            }.padding(.vertical, 2)
        }.padding(.bottom, 10)
    }

    private func slider(_ label: String, _ lo: Int, _ hi: Int, _ kp: WritableKeyPath<Current, Int>) -> some View {
        row(label, lo, hi, Binding(get: { cur[keyPath: kp] }, set: { cur[keyPath: kp] = $0 }))
    }
    private func sliderOpt(_ label: String, _ lo: Int, _ hi: Int, _ kp: WritableKeyPath<Current, Int?>) -> some View {
        row(label, lo, hi, Binding(get: { cur[keyPath: kp] ?? 0 }, set: { cur[keyPath: kp] = $0 }))
    }
    private func row(_ label: String, _ lo: Int, _ hi: Int, _ value: Binding<Int>) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(Color.mute).frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()); scheduleSend() }),
                   in: Double(lo)...Double(hi), step: 1) { editing in
                dragging += editing ? 1 : -1
                model.interacting = dragging > 0
            }.tint(.accentA)
            Text("\(value.wrappedValue)").monospacedDigit().frame(width: 36, alignment: .trailing)
        }.padding(.vertical, 5)
    }
    private func scheduleSend() {
        sendTask?.cancel()
        let s = cur.settings, key = group.key
        sendTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { await model.applyManual(key, s) }
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Demo-Modus", isOn: $model.demo)
                } footer: { Text("Simulierte Lautsprecher, z. B. für den Simulator oder zum Ausprobieren.") }
                Section {
                    TextField("automatisch", text: $model.manualIP).keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit { model.resetBackend() }
                    Button("Lautsprecher neu suchen") { Task { await model.rescan(); dismiss() } }
                } header: { Text("Sonos-IP (optional)") } footer: {
                    Text("Normalerweise findet die App die Lautsprecher per Bonjour selbst. Trägst du die IP eines Lautsprechers ein, wird sie direkt verwendet.")
                }
                Section { } footer: { Text("Die Quellen-Automatik (Preset bei TV/Radio/Spotify/Line-in) läuft nur, solange die App geöffnet ist. Presets werden auf diesem iPhone gespeichert.") }
            }
            .navigationTitle("Einstellungen").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { model.resetBackend(); dismiss() } } }
        }
    }
}
