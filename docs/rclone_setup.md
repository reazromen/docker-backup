# Rclone Konfiguration

Diese Anleitung beschreibt, wie du Rclone für die Verbindung zu deinem Cloud-Speicher (Remote) konfigurierst. Rclone dient als Übertragungsschicht für Restic, um die verschlüsselten Backups sicher auf externen Speicher zu übertragen.

## 1. Konfigurationsmethoden

Es gibt zwei Wege, Rclone zu konfigurieren:

### A. Interaktiver Assistent (Empfohlen für neue Setups)

Rclone bietet einen geführten Assistenten, der dich durch alle notwendigen Einstellungen leitet.

```bash
rclone config
```

1. Wähle `n` für "New remote".
2. Gib einen Namen ein (z. B. `1blu` oder `internxt-webdav`).
3. Wähle den Typ des Speichers aus der Liste (z. B. `webdav` oder `s3`).
4. Folge den spezifischen Anweisungen für deinen Anbieter.

### B. Manuelle Konfiguration (Direktes Editieren)

Du kannst die Konfigurationsdatei auch direkt bearbeiten oder erstellen. Rclone ist ein Kommandozeilenwerkzeug (CLI) und **kein Hintergrunddienst**. Das bedeutet:
- Es ist **kein Neustart** eines Dienstes erforderlich.
- Rclone liest die Konfigurationsdatei bei **jedem Befehlsaufruf** neu ein.

Der Standardpfad für die Konfiguration ist `~/.config/rclone/rclone.conf`.

Hier sind Beispiele für die in diesem Projekt genutzten Anbieter:

#### Beispiel: 1blu (WebDAV) – Primärer Backup-Speicher
```ini
[1blu]
type = webdav
url = https://u318508.oberon.1blu.de
vendor = other
user = [dein_benutzername]
pass = [dein_verschlüsseltes_passwort]
```

#### Beispiel: Internxt (WebDAV) – Sekundärer Sync-Speicher
```ini
[internxt-webdav]
type = webdav
url = https://webdav.internxt.com
vendor = other
user = [deine_internxt_email]
pass = [dein_verschlüsseltes_passwort]
```

> Der Name `internxt-webdav` muss mit dem Wert von `INTERNXT_RCLONE_REMOTE` in deiner `backup.conf` übereinstimmen.

#### Beispiel: Hetzner Object Storage (S3)
```ini
[hetzner]
type = s3
provider = Hetzner
access_key_id = [dein_key_id]
secret_access_key = [dein_secret]
region = fsn1
endpoint = fsn1.your-objectstorage.com
```

> **Hinweis zur Sicherheit:** Passwörter in der `rclone.conf` sind standardmäßig mit einem einfachen Verfahren verschleiert. Wenn du sie manuell einträgst, kannst du `rclone obscure "dein_passwort"` nutzen, um den verschleierten String für das Feld `pass` zu generieren.

### Beispiel: Hugging Face Storage Bucket (S3) - zusaetzliche Offsite-Kopie

Hugging Face Storage Buckets stellen eine S3-kompatible API bereit. Verwende
einen separaten Write-Token und daraus erzeugte S3-Zugangsdaten. Die
Zugangsdaten gehoeren **nicht** in dieses Git-Repository.

```ini
[huggingface]
type = s3
provider = Other
access_key_id = HFAK...
secret_access_key = ...
region = us-east-1
endpoint = https://s3.hf.co/reazromen
force_path_style = true
list_version = 2
```

In `backup.conf`:

```bash
HF_RCLONE_REMOTE="huggingface"
HF_BUCKET="nextcloud-backup"
HF_PREFIX="restic"
```

Der normale Restic-Backup-Lauf bleibt das primaere Ziel. Nach einem
erfolgreichen Backup wird das bereits verschluesselte Restic-Repository mit
`rclone sync` in den privaten Hugging-Face-Bucket gespiegelt. Wenn Hugging Face
nicht erreichbar ist, wird das primaere Backup nicht als fehlgeschlagen
behandelt.

## 2. Speicherort der Konfiguration

Stelle sicher, dass der Pfad zur Konfigurationsdatei in der `.env` korrekt gesetzt ist:

```env
RCLONE_CONFIG=/root/.config/rclone/rclone.conf
```

Und dass die Datei die richtigen Berechtigungen hat:

```bash
mkdir -p ~/.config/rclone
chmod 700 ~/.config/rclone
chmod 600 ~/.config/rclone/rclone.conf
```

## 3. Funktionstests

Nachdem die Konfiguration abgeschlossen ist, solltest du prüfen, ob Rclone deine Remotes erkennt und die Verbindung funktioniert.

### Remotes auflisten
```bash
rclone listremotes
```
Erwartete Ausgabe (Beispiel): `1blu:` und `internxt-webdav:`

### Verbindung prüfen
Listet alle Verzeichnisse im Root des Remotes auf:
```bash
rclone lsd 1blu:
rclone lsd internxt-webdav:
```

### Schreibtest
```bash
echo "test" > rclone_test.txt
rclone copy rclone_test.txt 1blu:
rclone ls 1blu:rclone_test.txt
rclone delete 1blu:rclone_test.txt
rm rclone_test.txt
```

## Nächste Schritte

Sobald die Verbindung steht, kannst du das Restic-Repository initialisieren. Siehe dazu die [Hauptanleitung](../readme.de.md#3-restic-repository-initialisieren).
