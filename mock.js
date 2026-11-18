// Simulierte Sonos-Anlage für Demo/Tests ohne Hardware.
const speakers = [
  ['RINCON_A', 'Wohnzimmer'], ['RINCON_B', 'Küche'], ['RINCON_C', 'Schlafzimmer'], ['RINCON_D', 'Terrasse'],
].map(([id, name], i) => ({ id, name, ip: `mock-${i}`, volume: 20 + i * 8, bass: 0, treble: 0, loudness: true }));
const layout = [['RINCON_A', 'RINCON_B'], ['RINCON_C'], ['RINCON_D']];

export const mock = {
  async topology() {
    return layout.map((ids) => ({ coordinator: ids[0], members: ids.map((id) => { const { id: i, name, ip } = speakers.find((s) => s.id === id); return { id: i, name, ip }; }) }));
  },
  async read(ip) { const s = speakers.find((x) => x.ip === ip); return { volume: s.volume, bass: s.bass, treble: s.treble, loudness: s.loudness }; },
  async readGroupVolume(group) { return Math.round(group.members.reduce((a, m) => a + speakers.find((s) => s.ip === m.ip).volume, 0) / group.members.length); },
  async apply(group, st) {
    for (const m of group.members) {
      const s = speakers.find((x) => x.ip === m.ip);
      for (const k of ['volume', 'bass', 'treble', 'loudness']) if (st[k] != null) s[k] = st[k];
    }
  },
};
