// Simulierte Sonos-Anlage für Demo/Tests ohne Hardware.
const speakers = [
  ['RINCON_A', 'Wohnzimmer'], ['RINCON_B', 'Küche'], ['RINCON_C', 'Schlafzimmer'], ['RINCON_D', 'Terrasse'],
].map(([id, name], i) => ({ id, name, ip: `mock-${i}`, volume: 20 + i * 8, bass: 0, treble: 0, loudness: true, ...(id === 'RINCON_A' && { sub: 0, rear: 0, rearMusic: 0 }) }));
const layout = [['RINCON_A', 'RINCON_B'], ['RINCON_C'], ['RINCON_D']];

const sources = {}; // Koordinator-ID -> { uri, state }
export const mock = {
  setSource(id, uri, state = 'PLAYING') { sources[id] = { uri, state }; },
  async source(group) { return sources[group.coordinator] ?? { uri: '', state: 'STOPPED' }; },
  async topology() {
    return layout.map((ids) => ({ coordinator: ids[0], members: ids.map((id) => { const { id: i, name, ip, sub, rear } = speakers.find((s) => s.id === id); return { id: i, name, ip, hasSub: sub != null, hasRears: rear != null }; }) }));
  },
  async read(ip) { const s = speakers.find((x) => x.ip === ip); return { volume: s.volume, bass: s.bass, treble: s.treble, loudness: s.loudness, ...(s.sub != null && { sub: s.sub }), ...(s.rear != null && { rear: s.rear, rearMusic: s.rearMusic }) }; },
  async readGroupVolume(group) { return Math.round(group.members.reduce((a, m) => a + speakers.find((s) => s.ip === m.ip).volume, 0) / group.members.length); },
  async apply(group, st) {
    for (const m of group.members) {
      const s = speakers.find((x) => x.ip === m.ip);
      for (const k of ['volume', 'bass', 'treble', 'loudness']) if (st[k] != null) s[k] = st[k];
      if (st.sub != null && s.sub != null) s.sub = st.sub;
      for (const k of ['rear', 'rearMusic']) if (st[k] != null && s[k] != null) s[k] = st[k];
    }
  },
};
