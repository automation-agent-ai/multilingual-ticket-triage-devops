# Liora DevOps Pre-Defense – Live-Demo-Drehbuch

**Projekt:** AI Ticket Triage Agent – From Local Prototype to Cloud-Native Platform  
**Zielzeit:** 8–12 Minuten  
**Demo-Systeme:** GitHub, AWS EC2/k3s, Swagger, Prometheus, Grafana, Restic

---

## 1. Architecture Overview (ca. 1 Minute)

**Zeigen:** Architekturfolie.

**Sagen:**

„Ausgangspunkt war ein lokaler KI-Prototyp zur automatischen Klassifizierung von Support-Tickets. Die Anwendung wurde containerisiert und auf AWS EC2 migriert.

Die technische Grundlage:
- **AWS EC2** t3.medium Instanz
- **k3s** Kubernetes-Distribution – lightweight, aber vollständig
- **Amazon Bedrock** für KI-Inferenz
- **Hetzner public HTTPS gateway** über Tailscale für sicheren Zugriff

Die Plattform nutzt drei logische Kubernetes-Namespaces:
- **triage-dev** – Entwicklungsumgebung
- **triage-prod** – Produktivumgebung
- **triage-monitoring** – Prometheus und Grafana

DEV und PROD sind logisch getrennte Namespaces im selben k3s-Cluster. Monitoring läuft separat, aber in derselben Infrastruktur."

---

## 2. Live Swagger Demonstration (ca. 2 Minuten)

**Browser öffnen:**

https://triage.automation-agent.ai/docs

**Vorgehen:**

1. Mit den eingerichteten Zugangsdaten anmelden (**HTTP Basic Authentication** am Gateway).
2. Swagger UI zeigen – öffentlich zugängliche API-Dokumentation.
3. Endpoint **POST /triage** demonstrieren.
4. Auf „Try it out" klicken.
5. Test-Payload einfügen:

```json
{
  "ticket_id": "demo-001",
  "subject": "Double charge on my invoice",
  "body": "I was charged twice for my insurance premium this month. Please refund the duplicate payment immediately."
}
```

6. „Execute" klicken und Response zeigen.

**Sagen:**

„Der Agent analysiert das Ticket, klassifiziert das Thema (**topic**), bewertet die Dringlichkeit (**urgency**), schlägt die nächste Bearbeitungsaktion (**next_action**) vor und gibt eine Konfidenzschätzung (**confidence**) zurück.

Die KI-Inferenz nutzt **Amazon Bedrock**. Wenn verfügbar, zeigt die Response zusätzliche Inferenz-Metadaten. Externe Folgeaktionen, wie E-Mail-Versand oder Ticket-Routing, sind in dieser Demo simuliert."

**Wichtig:** Nur Felder erklären, die tatsächlich in der Response erscheinen.

**Erwartete strukturierte Response:**
- `topic`: z. B. "billing"
- `urgency`: "high"
- `next_action`: z. B. "escalate_to_finance"
- `confidence`: 0.85–0.95
- `bedrock_metadata` (falls vorhanden): Inference-Evidence

---

## 3. Kubernetes Live Demonstration (ca. 1,5 Minuten)

**AWS-Terminal öffnen.**

**Cluster und Namespaces zeigen:**

```bash
kubectl get nodes
kubectl get namespaces
kubectl get pods -A -o wide
kubectl get deployments -A
kubectl get svc -A
```

**Sagen:**

„Wir verwenden **eine AWS EC2 t3.medium Instanz** mit **k3s**, einem leichtgewichtigen Kubernetes. Die Anwendung ist in drei **Namespaces** organisiert:

- **triage-dev** – Entwicklungsumgebung
- **triage-prod** – Produktivumgebung
- **triage-monitoring** – Prometheus und Grafana

DEV und PROD sind **logisch getrennte Namespaces**, nicht physisch separate Cluster. Das ermöglicht paralleles Testen und stabile Produktivbereitstellung in derselben Infrastruktur.

**Prometheus und Grafana** sind zusätzliche **Pods im Monitoring-Namespace**, nicht separate Namespaces."

**DEV und PROD Deployments zeigen:**

```bash
kubectl get deployments -n triage-dev
kubectl get deployments -n triage-prod
kubectl get pods -n triage-monitoring
```

**Fallback:**

Sollte `kubectl` nicht direkt verfügbar sein:

```bash
sudo k3s kubectl get nodes
sudo k3s kubectl get namespaces
```

---

## 4. Prometheus Demonstration – TWO TERMINALS (ca. 2 Minuten)

**WICHTIG:** Der öffentliche `/metrics`-Endpoint ist durch Hetzner Nginx **absichtlich blockiert** (HTTP 404). Das ist eine bewusste Sicherheitsentscheidung und bleibt so.

**Ziel:** Application Metrics intern über Port-Forwarding zeigen, ohne öffentlichen Zugriff zu öffnen.

### Terminal A (AWS EC2):

Port-Forward vom Kubernetes Service zum lokalen Port 18000:

```bash
kubectl -n triage-prod port-forward svc/ticket-triage 18000:8000
```

**Laufen lassen.**

### Terminal B (AWS EC2):

Metrics lokal abrufen:

```bash
curl -s http://127.0.0.1:18000/metrics | head -30
```

**Sagen:**

„Die Anwendung stellt intern Prometheus-Metriken am `/metrics`-Endpoint bereit. **Prometheus** scrapt diese Metriken regelmäßig innerhalb des Clusters.

Der öffentliche Zugriff über das Hetzner-Gateway ist bewusst blockiert. Wir greifen hier lokal per Port-Forwarding zu, um die Metriken zu demonstrieren."

**Erwartete Ausgabe:**

```
# HELP python_gc_objects_collected_total Objects collected during gc
# TYPE python_gc_objects_collected_total counter
python_gc_objects_collected_total{generation="0"} 234.0
...
http_requests_total{method="POST",endpoint="/triage"} 12
```

**Port-Forward nach der Demo beenden:**

`Ctrl+C` in Terminal A.

---

## 5. Prometheus Web UI – Secure Port Forwarding (ca. 1,5 Minuten)

**WICHTIG:** Prometheus bleibt **intern**. Kein öffentlicher Zugriff. Port-Forwarding nur für Demo.

### Schritt 1: Kubernetes Service prüfen

```bash
kubectl get svc -n triage-monitoring
```

Erwartete Ausgabe:

```
NAME         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
prometheus   ClusterIP   10.43.197.20    <none>        9090/TCP   4h
grafana      ClusterIP   10.43.163.173   <none>        3000/TCP   4h
```

### Schritt 2: Port-Forward auf AWS EC2

```bash
kubectl -n triage-monitoring port-forward svc/prometheus 19090:9090
```

**Laufen lassen.**

### Schritt 3: Remote Port nach Laptop forwarden

**Sagen:**

„Ich nutze **VS Code Remote SSH**, um den Remote-Port 19090 auf meinen Laptop zu tunneln. VS Code zeigt automatisch eine Port-Forwarding-Benachrichtigung, oder ich kann Ports manuell im PORTS-Tab hinzufügen."

**Im Browser auf dem Laptop öffnen:**

http://localhost:19090

### Prometheus UI zeigen:

1. **Status → Targets** öffnen
2. **UP/DOWN-Status** der Scrape Targets zeigen:
   - `triage-dev/ticket-triage:8000/metrics`
   - `triage-prod/ticket-triage:8000/metrics`
3. **Graph-Tab** öffnen und einfache PromQL-Query ausführen:

```
up
```

**Sagen:**

„Prometheus scrapt regelmäßig beide Umgebungen – DEV und PROD. Die **Targets** zeigen den Health-Status. Wir sehen hier, welche Services erreichbar sind und wann sie zuletzt gescrapt wurden.

Prometheus bleibt **intern** im Cluster. Wir öffnen ihn **nicht öffentlich** über den Hetzner-Gateway oder AWS Security Groups."

**Port-Forward beenden:**

`Ctrl+C` nach der Demo.

---

## 6. Grafana Live Dashboard (ca. 1,5 Minuten)

**Browser öffnen:**

https://grafana.automation-agent.ai/

**Vorgehen:**

1. **HTTP Basic Authentication** am Hetzner Gateway (Zugangsdaten: siehe Credentials-Referenz unten).
2. **Grafana-Login** mit application credentials.
3. Dashboard **„Ticket Triage AWS DEV vs PROD"** öffnen.

**Dashboard zeigen:**

- **Request Counts** für DEV und PROD
- **Latency** (P50, P95, P99, falls vorhanden)
- **Error Rates** (falls vorhanden)
- **Comparison Panels** zwischen DEV und PROD

**Sagen:**

„Grafana visualisiert die Prometheus-Metriken. Wir sehen hier die **Anwendungsmetriken** aus beiden Umgebungen – DEV und PROD – auf einem Dashboard.

Das ermöglicht uns, Performance-Unterschiede zu erkennen, Anomalien zu überwachen und die Auswirkungen von Deployments zu vergleichen."

**Gateway-Authentifizierung:**

Das Grafana-Dashboard ist durch **zwei Ebenen** geschützt:
1. **Nginx Basic Auth** am Hetzner-Gateway
2. **Grafana Application Login**

---

## 7. GitHub CI/CD (ca. 1,5 Minuten)

**Repository:**

https://github.com/automation-agent-ai/multilingual-ticket-triage-devops

**Actions:**

https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions

**Vorgehen:**

1. Einen **erfolgreichen CI-Lauf** öffnen.
2. **Jobs** zeigen:
   - `pytest` – Unit Tests und Integration Tests
   - `build` – Docker Container Build
   - `ghcr-publish` – Push to GitHub Container Registry
   - `trivy-scan` – Security Vulnerability Scan

**PR #3 öffnen:**

https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/pull/3

**Sagen:**

„Unser **CI-Prozess** prüft automatisiert die Anwendung: Tests, Container-Build, Security-Scan und Veröffentlichung in der **GitHub Container Registry**.

Die erweiterte **AWS-CD-Pipeline** ist im Feature-Branch implementiert und validiert. Ihre automatische Aktivierung ist noch von **IAM-, OIDC- und SSM-Voraussetzungen** abhängig.

Die existierenden erfolgreichen CI-Runs zeigen, dass der Build- und Test-Prozess stabil läuft. **AWS CD** – das automatische Deployment auf AWS – wurde in PR #3 konfiguriert, aber noch nicht aktiviert."

**Current Branches zeigen:**

- `main` – stable production baseline
- `feature/aws-cd-phase12c-final` – CD implementation (PR #3)

**WICHTIG:** **Nicht behaupten**, dass automatisches AWS-Deployment über die neue CD-Pipeline bereits erfolgt ist, es sei denn, es gibt Workflow-Evidence dafür.

---

## 8. Backup Automation and Restore (ca. 2 Minuten)

**Backup-Strategie:**

Wir nutzen **lokale verschlüsselte Restic-Backups** auf dem bestehenden **AWS EBS Volume**.

**Daten:**
- **4.000 historische Tickets** in DuckDB
- **3.206 LanceDB Vektoren** (1.024 Dimensionen)
- Automatische **SHA256-Validierung**

### Backup Timer zeigen:

```bash
sudo systemctl list-timers --all | grep liora
```

Erwartete Ausgabe:

```
Tue 2026-10-13 02:00:00 UTC  ... liora-restic-backup.timer  liora-restic-backup.service
```

### Timer-Konfiguration zeigen:

```bash
sudo systemctl cat liora-restic-backup.timer
```

**Sagen:**

„Der Backup läuft täglich um **02:00 UTC** über einen **systemd Timer**. Die Konfiguration ist persistent – falls das System zur Backup-Zeit offline ist, wird das Backup beim nächsten Start nachgeholt."

### Letzten Backup-Lauf prüfen:

```bash
sudo journalctl -u liora-restic-backup.service -n 25 --no-pager
```

### Restic Repository und Snapshots zeigen:

**Repository Path:** `/var/backups/liora-restic`

```bash
sudo restic -r /var/backups/liora-restic snapshots
```

**Restore-Test Ergebnis (falls dokumentiert):**

Dokumentiertes Restore-Testergebnis aus Phase 11C zeigen oder referenzieren.

**Sagen:**

„Wir haben die Wiederherstellung getestet:
- **4.000 historische Tickets** erfolgreich wiederhergestellt
- **3.206 Vektoren** validiert
- **SHA256-Checksummen** bestätigen Datenintegrität

Das Python-Skript bereitet die Daten vor, dann erstellt **Restic** ein **verschlüsseltes, inkrementelles Backup**."

**Offsite (getestet, Oktober 2025):**

Nach erfolgreichem lokalem Restic-Lauf kopiert `liora-restic-offsite-copy.service` die Snapshots per **`restic copy`** über **Tailscale** zu einem **Hetzner REST**-Repository (`restic serve`). Credentials liegen nur unter `/etc/liora-backup/` (nicht im Git).

**Journal prüfen:**

```bash
sudo journalctl -u liora-restic-offsite-copy.service -n 25 --no-pager
```

**WICHTIG – Limitation:**

„Lokale Backups auf EBS schützen gegen Applikationsfehler. **Offsite-Kopie nach Hetzner** schützt zusätzlich gegen Verlust des EC2-EBS-Volumes. Ein **vollständiger Plattform-Disaster-Recovery-Lauf** (kompletter EC2-Neuaufbau inkl. Kubernetes, DNS und End-to-End-Wiederherstellung) ist **nicht** als abgeschlossener Test dokumentiert."

**Unterscheidung:**
- ✅ **Getestet:** Lokale Restic-Backups, Restore-Validierung (Phase 11C), täglicher Timer, Hetzner-Offsite-`restic copy` (Sprint F01/G02)
- ⏳ **Geplant / optional:** Terraform-Modul `aws-restic` (S3-Bucket) als zusätzliche Ziel-Option; vollständiger DR-Tabletop über gesamte Plattform

---

## 9. Terraform Infrastructure as Code (ca. 1 Minute)

**Location:**

```
/home/ubuntu/workspaces/terraform-phase12d/
```

**In Cursor oder Terminal zeigen:**

```bash
ls -la /home/ubuntu/workspaces/terraform-phase12d/
```

**Dateien:**
- `README.md`
- `PHASE12D_FINAL_REPORT.md`
- `aws-infra/` – Terraform Modules

**Sagen:**

„Im Repository liegt **Terraform-Konfiguration** für ausgewählte AWS-Bausteine (z. B. GitHub OIDC, Deploy-IAM, optional S3/Restic-Bucket, Monitoring-Module). **Die laufende EC2/k3s-Produktionsinstanz wird damit nicht vollständig verwaltet** — sie wurde manuell aufgebaut; Terraform dient vor allem IaC für CI/CD-Voraussetzungen und dokumentierte Module.

`terraform validate` / `plan` sind für die Module durchgeführt; **`terraform apply` auf die gesamte Produktions-EC2 ist nicht der aktuelle Betriebsmodus** und erfolgt nicht während der Defense."

**WICHTIG:** **Kein `terraform apply` während der Defense.**

---

## 10. Summary and Troubleshooting

### Execution Timeline (8–12 Minuten)

| Section | Duration | Cumulative |
|---------|----------|------------|
| 1. Architecture Overview | 1:00 | 1:00 |
| 2. Swagger Demo | 2:00 | 3:00 |
| 3. Kubernetes Demo | 1:30 | 4:30 |
| 4. Prometheus Metrics | 2:00 | 6:30 |
| 5. Prometheus UI | 1:30 | 8:00 |
| 6. Grafana Dashboard | 1:30 | 9:30 |
| 7. GitHub CI/CD | 1:30 | 11:00 |
| 8. Backup & Restore | 2:00 | 13:00 |
| 9. Terraform | 1:00 | 14:00 |

**Target:** 8–12 Minuten. Bei Zeitdruck Prometheus UI oder Backup Details kürzen.

---

### Quick Command Reference

**Kubernetes:**

```bash
kubectl get nodes
kubectl get namespaces
kubectl get pods -A -o wide
kubectl get svc -A
```

**Prometheus Port-Forward:**

```bash
# Application metrics
kubectl -n triage-prod port-forward svc/ticket-triage 18000:8000
curl -s http://127.0.0.1:18000/metrics | head -30

# Prometheus UI
kubectl -n triage-monitoring port-forward svc/prometheus 19090:9090
# Then: http://localhost:19090 on laptop via VS Code
```

**Backup Status:**

```bash
sudo systemctl list-timers --all | grep liora
sudo systemctl status liora-restic-backup.timer
sudo journalctl -u liora-restic-backup.service -n 25 --no-pager
sudo restic -r /var/backups/liora-restic snapshots
```

---

### Browser URLs

| Service | URL | Auth |
|---------|-----|------|
| Swagger API | https://triage.automation-agent.ai/docs | HTTP Basic (Gateway) |
| Grafana Dashboard | https://grafana.automation-agent.ai/ | HTTP Basic (Gateway) + Grafana Login |
| Prometheus UI | http://localhost:19090 | Port-Forward only |
| GitHub Actions | https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions | GitHub |
| PR #3 | https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/pull/3 | GitHub |

---

### Credentials Reference

**IMPORTANT:** Actual passwords are stored in:

```
~/.config/liora/demo-credentials.md
```

**File permissions:** `0600` (owner-only access)

**Never commit to Git or expose in public documentation.**

#### Swagger API (triage.automation-agent.ai)

- **Gateway Auth:** HTTP Basic Authentication
- **Username:** `guest`
- **Password:** See private credentials file

#### Grafana (grafana.automation-agent.ai)

**Layer 1 – Nginx Gateway:**
- **Username:** `guest`
- **Password:** See private credentials file

**Layer 2 – Grafana Application:**
- **Username:** `guest`
- **Role:** Viewer
- **Password:** See private credentials file

---

### Verified vs. Planned Functionality

| Feature | Status | Evidence |
|---------|--------|----------|
| ✅ Kubernetes DEV/PROD | **Verified** | Running pods, deployments, services |
| ✅ Public HTTPS API | **Verified** | https://triage.automation-agent.ai/docs |
| ✅ Amazon Bedrock Integration | **Verified** | Inference responses with confidence |
| ✅ Prometheus Metrics | **Verified** | `/metrics` endpoint, internal scraping |
| ✅ Grafana Dashboard | **Verified** | Live dashboard, DEV vs PROD comparison |
| ✅ GitHub CI | **Verified** | Successful test, build, scan runs |
| ✅ GHCR Container Registry | **Verified** | Published images |
| ✅ Restic Backup Automation | **Verified** | Daily timer, snapshots, restore test |
| ⏳ AWS CD Auto-Deploy | **Planned** | Configured in PR #3, awaiting IAM/OIDC |
| ⏳ Terraform Apply | **Planned** | Validated, not yet applied |
| ✅ Hetzner REST Offsite (`restic copy`) | **Verified** | Timer + `OnSuccess` offsite unit; journal SUCCESS (Oct 2025) |
| ⏳ S3 Restic bucket (Terraform module) | **Planned / not active path** | `infra/terraform/aws-restic` documented; production uses EBS + Hetzner |
| ⏳ Full platform DR exercise | **Planned** | App data restore tested; full EC2 rebuild not proven end-to-end |

---

### Fallback Strategies

**Swagger nicht erreichbar:**
- Architektur zeigen
- Bereits gespeicherte Test-Response demonstrieren

**Kubernetes-Kommando funktioniert nicht:**
- Alternative: `sudo k3s kubectl <command>`

**Grafana nicht erreichbar:**
- Auf bereits vorhandene Dashboard-Screenshots zurückgreifen

**GitHub Actions zeigt keinen neuen erfolgreichen Run:**
- Einen früheren erfolgreichen CI-Lauf zeigen
- CD-Status korrekt einordnen: konfiguriert, aber noch nicht aktiviert

**Backup-Timer nicht aktiv:**
- Bestandene lokale Restic-Tests zeigen
- Geplante Automatisierung ausdrücklich als "in Testphase" kennzeichnen

**Port-Forwarding schlägt fehl:**
- Service-Namen nochmal prüfen: `kubectl get svc -n <namespace>`
- Alternative Ports verwenden: 19091, 18001

**VS Code Remote Port Forwarding nicht verfügbar:**
- SSH-Tunnel manuell aufbauen:
  ```bash
  ssh -L 19090:localhost:19090 ubuntu@<aws-ip>
  ```

---

### Defense-Rules

**NIEMALS während der Defense:**

- ❌ `terraform apply`
- ❌ Git merges in `main`
- ❌ PROD deployments
- ❌ Backup-Restores auf PROD
- ❌ Änderungen an AWS Security Groups
- ❌ Änderungen an Hetzner Nginx (außer getestet und approved)
- ❌ Prometheus oder Grafana öffentlich öffnen

**Immer:**

- ✅ `nginx -t` vor `nginx reload`
- ✅ Readonly-Befehle bevorzugen
- ✅ Bereits getestete Pfade demonstrieren
- ✅ Bei Problemen: Fallback-Screenshots oder dokumentierte Ergebnisse zeigen
- ✅ Verified vs. Planned klar unterscheiden

---

**Abschluss-Statement:**

„Das Projekt zeigt den Weg vom lokalen KI-Prototyp zu einer **Cloud-Native-Anwendung**: containerisiert, auf Kubernetes betrieben, mit Amazon Bedrock integriert, überwacht und mit Backup- und CI/CD-Komponenten ergänzt.

Die nächsten Ausbauschritte sind:
- Aktivierung des automatischen **AWS-Deployments** über die CD-Pipeline
- **Externe S3-Backups** und vollständige **Disaster-Recovery-Tests**
- Terraform-Rollout für vollständige **Infrastructure as Code**"
