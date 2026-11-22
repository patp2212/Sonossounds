// Minimaler Sonos-Client über das lokale UPnP/SOAP-Protokoll (Port 1400). Keine Abhängigkeiten.
import dgram from 'node:dgram';

const RC = { path: '/MediaRenderer/RenderingControl/Control', urn: 'urn:schemas-upnp-org:service:RenderingControl:1' };
const GRC = { path: '/MediaRenderer/GroupRenderingControl/Control', urn: 'urn:schemas-upnp-org:service:GroupRenderingControl:1' };
const ZGT = { path: '/ZoneGroupTopology/Control', urn: 'urn:schemas-upnp-org:service:ZoneGroupTopology:1' };

const esc = (s) => String(s).replace(/[<>&"']/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[c]);
export const unesc = (s) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');

export async function soap(ip, svc, action, args = {}) {
  const body = Object.entries(args).map(([k, v]) => `<${k}>${esc(v)}</${k}>`).join('');
  const xml = `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:${action} xmlns:u="${svc.urn}">${body}</u:${action}></s:Body></s:Envelope>`;
  const res = await fetch(`http://${ip}:1400${svc.path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'text/xml; charset="utf-8"', SOAPACTION: `"${svc.urn}#${action}"` },
    body: xml,
    signal: AbortSignal.timeout(4000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Sonos ${action} fehlgeschlagen (${res.status}) auf ${ip}`);
  return text;
}
const tag = (xml, name) => xml.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`))?.[1];

export function discover(timeoutMs = 2500) {
  return new Promise((resolve) => {
    const found = new Set();
    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    const msg = Buffer.from(['M-SEARCH * HTTP/1.1', 'HOST: 239.255.255.250:1900', 'MAN: "ssdp:discover"', 'MX: 1', 'ST: urn:schemas-upnp-org:device:ZonePlayer:1', '', ''].join('\r\n'));
    sock.on('message', (m, rinfo) => { if (/ZonePlayer/i.test(m.toString())) found.add(rinfo.address); });
    sock.on('error', () => {});
    sock.bind(() => {
      try { sock.send(msg, 1900, '239.255.255.250'); } catch {}
    });
    setTimeout(() => { try { sock.close(); } catch {} resolve([...found]); }, timeoutMs);
  });
}

export function parseTopology(zoneGroupStateXml) {
  const xml = unesc(zoneGroupStateXml);
  const groups = [];
  for (const g of xml.matchAll(/<ZoneGroup\s+([^>]*)>([\s\S]*?)<\/ZoneGroup>/g)) {
    const coordinator = g[1].match(/Coordinator="([^"]+)"/)?.[1];
    const members = [];
    for (const m of g[2].matchAll(/<ZoneGroupMember\s+([^>]*?)\/?>/g)) {
      const attr = (n) => m[1].match(new RegExp(`\\b${n}="([^"]*)"`))?.[1];
      if (attr('Invisible') === '1') continue; // Subs / Surround-Satelliten
      const ip = attr('Location')?.match(/\/\/([^:/]+)/)?.[1];
      // Sub/Rears im Home-Theater-Verbund: die Pegel (SubGain, SurroundLevel, MusicSurroundLevel) liegen auf dem Hauptgerät
      members.push({ id: attr('UUID'), name: unesc(attr('ZoneName') ?? '?'), ip, hasSub: /:SW\b/.test(attr('HTSatChanMapSet') ?? ''), hasRears: /:(LR|RR)\b/.test(attr('HTSatChanMapSet') ?? '') });
    }
    if (!members.length) continue;
    groups.push({ coordinator, members });
  }
  return groups;
}

export async function getTopology(anyIp) {
  const res = await soap(anyIp, ZGT, 'GetZoneGroupState');
  return parseTopology(tag(res, 'ZoneGroupState') ?? '');
}

const inst = { InstanceID: 0 };
export async function readSpeaker(ip, hasSub = false, hasRears = false) {
  const num = async (a, extra = {}) => Number(tag(await soap(ip, RC, a, { ...inst, ...extra }), a.replace('Get', 'Current')));
  const [volume, bass, treble, loud] = await Promise.all([
    num('GetVolume', { Channel: 'Master' }), num('GetBass'), num('GetTreble'), num('GetLoudness', { Channel: 'Master' }),
  ]);
  const sub = hasSub ? await readSubGain(ip).catch(() => undefined) : undefined;
  const [rear, rearMusic] = hasRears ? await Promise.all([readEQ(ip, 'SurroundLevel'), readEQ(ip, 'MusicSurroundLevel')]).catch(() => []) : [];
  return { volume, bass, treble, loudness: !!loud, ...(sub != null && { sub }), ...(rear != null && { rear, rearMusic }) };
}
const readEQ = async (ip, type) => Number(tag(await soap(ip, RC, 'GetEQ', { ...inst, EQType: type }), 'CurrentValue'));
const readSubGain = (ip) => readEQ(ip, 'SubGain');
const AVT = { path: '/MediaRenderer/AVTransport/Control', urn: 'urn:schemas-upnp-org:service:AVTransport:1' };
/** Aktuelle Quelle eines Koordinators: URI, Transportzustand, Titel (bei Radio der Sendername). */
export async function getSource(ip) {
  const [media, tr] = await Promise.all([soap(ip, AVT, 'GetMediaInfo', inst), soap(ip, AVT, 'GetTransportInfo', inst)]);
  const title = unesc(tag(media, 'CurrentURIMetaData') ?? '').match(/<dc:title>([^<]*)/)?.[1];
  return { uri: unesc(tag(media, 'CurrentURI') ?? ''), state: tag(tr, 'CurrentTransportState'), title: title ? unesc(title) : undefined };
}
/** URI -> tv | spotify | linein | radio | other (null = nichts eingestellt) */
export function classifySource(uri) {
  if (!uri) return null;
  if (/^x-sonos-htastream:/.test(uri)) return 'tv';
  if (/spotify/i.test(uri)) return 'spotify';
  if (/^x-rincon-stream:/.test(uri)) return 'linein';
  if (/^(x-sonosapi-(stream|radio|hls)|aac|hls-radio|x-rincon-mp3radio):/.test(uri)) return 'radio';
  return 'other';
}
export async function readGroupVolume(coordIp) {
  return Number(tag(await soap(coordIp, GRC, 'GetGroupVolume', inst), 'CurrentVolume'));
}

const clamp = (v, a, b) => Math.min(b, Math.max(a, Math.round(Number(v))));
export async function applyToGroup(group, s) {
  const jobs = [];
  const coord = group.members.find((m) => m.id === group.coordinator) ?? group.members[0];
  if (s.volume != null) jobs.push(soap(coord.ip, GRC, 'SetGroupVolume', { ...inst, DesiredVolume: clamp(s.volume, 0, 100) }));
  for (const m of group.members) {
    if (s.bass != null) jobs.push(soap(m.ip, RC, 'SetBass', { ...inst, DesiredBass: clamp(s.bass, -10, 10) }));
    if (s.treble != null) jobs.push(soap(m.ip, RC, 'SetTreble', { ...inst, DesiredTreble: clamp(s.treble, -10, 10) }));
    if (s.sub != null && m.hasSub) jobs.push(soap(m.ip, RC, 'SetEQ', { ...inst, EQType: 'SubGain', DesiredValue: clamp(s.sub, -15, 15) }));
    if (s.rear != null && m.hasRears) jobs.push(soap(m.ip, RC, 'SetEQ', { ...inst, EQType: 'SurroundLevel', DesiredValue: clamp(s.rear, -15, 15) }));
    if (s.rearMusic != null && m.hasRears) jobs.push(soap(m.ip, RC, 'SetEQ', { ...inst, EQType: 'MusicSurroundLevel', DesiredValue: clamp(s.rearMusic, -15, 15) }));
    if (s.loudness != null) jobs.push(soap(m.ip, RC, 'SetLoudness', { ...inst, Channel: 'Master', DesiredLoudness: s.loudness ? 1 : 0 }));
  }
  await Promise.all(jobs);
}
