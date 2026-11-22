import assert from 'node:assert/strict';
import { parseTopology, classifySource } from './sonos.js';

const sample = `&lt;ZoneGroupState&gt;&lt;ZoneGroups&gt;&lt;ZoneGroup Coordinator="RINCON_1" ID="RINCON_1:5"&gt;&lt;ZoneGroupMember UUID="RINCON_1" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="Wohnzimmer" /&gt;&lt;ZoneGroupMember UUID="RINCON_S" Location="http://192.168.1.11:1400/xml/device_description.xml" ZoneName="Wohnzimmer" Invisible="1" /&gt;&lt;ZoneGroupMember UUID="RINCON_2" Location="http://192.168.1.12:1400/xml/device_description.xml" ZoneName="K&amp;uuml;che" /&gt;&lt;/ZoneGroup&gt;&lt;/ZoneGroups&gt;&lt;/ZoneGroupState&gt;`;
const g = parseTopology(sample);
assert.equal(g.length, 1);
assert.equal(g[0].members.length, 2, 'unsichtbare Mitglieder werden ignoriert');
assert.equal(g[0].members[1].ip, '192.168.1.12');
const withSub = parseTopology(`&lt;ZoneGroupState&gt;&lt;ZoneGroups&gt;&lt;ZoneGroup Coordinator="RINCON_1" ID="RINCON_1:5"&gt;&lt;ZoneGroupMember UUID="RINCON_1" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="TV" HTSatChanMapSet="RINCON_1:LF,RF;RINCON_S:SW"&gt;&lt;Satellite UUID="RINCON_S" Location="http://192.168.1.11:1400/xml/device_description.xml" ZoneName="Sub" Invisible="1" /&gt;&lt;/ZoneGroupMember&gt;&lt;/ZoneGroup&gt;&lt;/ZoneGroups&gt;&lt;/ZoneGroupState&gt;`);
assert.equal(withSub[0].members[0].hasSub, true, 'Sub im Verbund erkannt');
const withRears = parseTopology(`&lt;ZoneGroupState&gt;&lt;ZoneGroups&gt;&lt;ZoneGroup Coordinator="RINCON_1" ID="RINCON_1:5"&gt;&lt;ZoneGroupMember UUID="RINCON_1" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="TV" HTSatChanMapSet="RINCON_1:LF,RF;RINCON_R:LR,LTR;RINCON_Q:RR,RTR"&gt;&lt;/ZoneGroupMember&gt;&lt;/ZoneGroup&gt;&lt;/ZoneGroups&gt;&lt;/ZoneGroupState&gt;`);
assert.equal(withRears[0].members[0].hasRears, true, 'Rears im Verbund erkannt'); assert.equal(withSub[0].members[0].hasRears, false); assert.equal(g[0].members[0].hasSub, false);
assert.deepEqual(['x-sonos-htastream:R:spdif', 'x-sonos-spotify:abc', 'x-rincon-stream:R', 'x-sonosapi-stream:s1?sid=3', 'x-file-cifs://a', ''].map(classifySource), ['tv', 'spotify', 'linein', 'radio', 'other', null]);
console.log('parseTopology ok');

process.env.SONOS_MOCK = '1'; process.env.SONOS_DATA = '/tmp/sonos-test-presets.json';
await (await import('node:fs/promises')).rm(process.env.SONOS_DATA, { force: true }); // frischer Zustand pro Lauf
 process.env.PORT = '0';
const { server, pollSources } = await import('./server.js');
const { mock } = await import('./mock.js');
await new Promise((r) => server.listen(0, r));
const base = `http://localhost:${server.address().port}`;
const api = (p, b) => fetch(base + p, b && { method: 'POST', body: JSON.stringify(b) }).then((r) => r.json());
let { groups } = await api('/api/groups');
assert.equal(groups.length, 3);
const key = groups[0].key;
await api('/api/preset/apply', { key, presetId: 'bass' });
({ groups } = await api('/api/groups'));
assert.equal(groups[0].current.bass, 6); assert.equal(groups[0].active, 'bass');
assert.equal(groups[1].current.bass, 0, 'andere Gruppe unverändert');
await api('/api/apply', { key, volume: 10 });
({ groups } = await api('/api/groups'));
assert.equal(groups[0].active, null);
await api('/api/preset/update', { key, presetId: 'bass', volume: 22, bass: 3 });
await api('/api/preset/apply', { key, presetId: 'bass' });
({ groups } = await api('/api/groups'));
assert.equal(groups[0].current.bass, 3, 'Preset wurde überschrieben'); assert.equal(groups[0].presets.find((x) => x.id === 'bass').volume, 22);
assert.equal(groups[0].current.sub, 0, 'Sub wird gelesen'); assert.equal(groups[2].current.sub, undefined, 'Gruppe ohne Sub hat keinen Sub-Wert');
await api('/api/preset/update', { key, presetId: 'bass', volume: 22, bass: 3, sub: 7, rear: 4, rearMusic: -2 });
await api('/api/preset/apply', { key, presetId: 'bass' });
({ groups } = await api('/api/groups'));
assert.equal(groups[0].current.sub, 7, 'Sub-Pegel wird mit dem Preset gesetzt');
assert.equal(groups[0].current.rear, 4, 'Rear-Pegel (TV) wird mit dem Preset gesetzt'); assert.equal(groups[0].current.rearMusic, -2, 'Rear-Pegel (Musik) wird gesetzt'); assert.equal(groups[2].current.rear, undefined, 'Gruppe ohne Rears hat keinen Rear-Wert');
// Quellen-Automatik: TV -> Preset „bass“ (Gruppe 0 = RINCON_A)
const poll = async (n = 1) => { for (let i = 0; i < n; i++) await pollSources(); };
await api('/api/preset/apply', { key, presetId: 'normal' });
await api('/api/auto/set', { key, source: 'tv', presetId: 'bass' });
mock.setSource('RINCON_A', 'x-rincon-stream:RINCON_A'); await poll(3);                // Ausgangszustand: Line-in, keine Automatik hinterlegt
({ groups } = await api('/api/groups')); assert.equal(groups[0].active, 'normal'); assert.equal(groups[0].source.type, 'linein');
mock.setSource('RINCON_A', 'x-sonos-htastream:RINCON_A:spdif'); await poll(1);       // 1 Messung = Flackern, noch nichts
({ groups } = await api('/api/groups')); assert.equal(groups[0].active, 'normal', 'erst nach 2 Messungen');
await poll(1);
({ groups } = await api('/api/groups')); assert.equal(groups[0].active, 'bass', 'TV löst Preset aus'); assert.equal(groups[0].source.type, 'tv');
await api('/api/apply', { key, volume: 5 }); await poll(3);
({ groups } = await api('/api/groups')); assert.equal(groups[0].current.volume, 5, 'kein erneutes Anwenden ohne Wechsel');
assert.equal((await api('/api/auto/set', { key, source: 'xyz', presetId: null })).error, 'Unbekannte Quelle');
await api('/api/preset/delete', { key, presetId: 'bass' });
({ groups } = await api('/api/groups')); assert.deepEqual(groups[0].auto, {}, 'Automatik-Eintrag verschwindet mit dem Preset');
console.log('API ok'); server.close();
