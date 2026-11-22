# Sonossounds

Moderne, minimalistische Web-App für Sonos. Pro **Gruppe** (oder einzelnen Lautsprecher) gibt es einen
Preset-Switch, der Lautstärke, Bass, Höhen und Loudness auf einmal umschaltet – plus Slider für Feintuning.

## Start
```bash
npm run demo        # simulierte Lautsprecher, keine Hardware nötig
npm start           # echte Sonos im selben WLAN (automatische Erkennung via SSDP)
SONOS_IP=192.168.1.20 npm start   # falls Erkennung im Netz blockiert ist
```
Dann `http://<rechner-ip>:3000` im Browser (auch am Handy im selben WLAN) öffnen.
Auf dem Handy: „Zum Home-Bildschirm hinzufügen“ für App-Gefühl.

## Funktionsweise
- Spricht direkt lokal mit den Lautsprechern (UPnP/SOAP, Port 1400) – kein Cloud-Konto, keine Abhängigkeiten.
- Gruppen werden live aus der Sonos-Topologie gelesen. Gruppenlautstärke über `GroupRenderingControl`,
  Bass/Höhen/Loudness werden auf jedes Mitglied gesetzt.
- Presets gehören zur **Gruppe** (Schlüssel = Menge der Lautsprecher-IDs, also unabhängig von Raumnamen und Reihenfolge) in `presets.json` gespeichert. Angezeigt werden alle aktuellen Gruppen und alle Lautsprecher, die gerade einzeln stehen.
  Standard: Normal, Bass+, Nacht, Party. Eigene über „+ Speichern“ aus den aktuellen Slider-Werten.
- `npm test` prüft Topologie-Parser und API im Demo-Modus.

## Hinweis
Der Server muss im selben Netzwerk wie die Sonos laufen (nicht in der Cloud). Gegen echte Hardware ist
das noch ungetestet – gib Bescheid, falls etwas nicht passt.
