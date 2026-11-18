import assert from 'node:assert/strict';
import { parseTopology } from './sonos.js';

const sample = `&lt;ZoneGroupState&gt;&lt;ZoneGroups&gt;&lt;ZoneGroup Coordinator="RINCON_1" ID="RINCON_1:5"&gt;&lt;ZoneGroupMember UUID="RINCON_1" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="Wohnzimmer" /&gt;&lt;ZoneGroupMember UUID="RINCON_S" Location="http://192.168.1.11:1400/xml/device_description.xml" ZoneName="Wohnzimmer" Invisible="1" /&gt;&lt;ZoneGroupMember UUID="RINCON_2" Location="http://192.168.1.12:1400/xml/device_description.xml" ZoneName="K&amp;uuml;che" /&gt;&lt;/ZoneGroup&gt;&lt;/ZoneGroups&gt;&lt;/ZoneGroupState&gt;`;
const g = parseTopology(sample);
assert.equal(g.length, 1);
assert.equal(g[0].members.length, 2, 'unsichtbare Mitglieder werden ignoriert');
assert.equal(g[0].members[1].ip, '192.168.1.12');
console.log('parseTopology ok');

process.env.SONOS_MOCK = '1'; process.env.SONOS_DATA = '/tmp/sonos-test-presets.json'; process.env.PORT = '0';
const { server } = await import('./server.js');
await new Promise((r) => server.listen(0, r));
const base = `http://localhost:${server.address().port}`;
const api = (p, b) => fetch(base + p, b && { method: 'POST', body: JSON.stringify(b) }).then((r) => r.json());
let { groups } = await api('/api/groups');
assert.equal(groups.length, 3);
const key = groups[0].key; assert.ok(groups[0].grouped);
await api('/api/preset/apply', { key, presetId: 'bass' });
({ groups } = await api('/api/groups'));
assert.equal(groups[0].current.bass, 6); assert.equal(groups[0].active, 'bass');
assert.equal(groups[1].current.bass, 0, 'andere Gruppe unverändert');
await api('/api/apply', { key, volume: 10 });
({ groups } = await api('/api/groups'));
assert.equal(groups[0].active, null);
console.log('API ok'); server.close();
