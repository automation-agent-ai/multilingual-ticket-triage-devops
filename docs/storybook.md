# Liora DevOps Pre-Defense – Live-Demo-Drehbuch

**Projekt:** AI Ticket Triage Agent – From Local Prototype to Cloud-Native Platform  
**Zielzeit:** ca. 8–10 Minuten  
**Demo-Systeme:** GitHub, AWS EC2/k3s, Swagger, Grafana, Restic

## 1. Einstieg: Gesamtarchitektur (ca. 45 Sekunden)

**Zeigen:** Architekturfolie.

**Sagen:**

„Ausgangspunkt war eine lokal entwickelte KI-Anwendung zur automatischen Klassifizierung von Support-Tickets. Die Anwendung wurde anschließend containerisiert und auf AWS EC2 mit Kubernetes und Amazon Bedrock migriert.

Die Plattform umfasst DEV und PROD, Monitoring, CI/CD und automatisierte Datensicherung.“

## 2. Anwendung live demonstrieren (ca. 2 Minuten)

**Browser öffnen:**

https://triage.automation-agent.ai/docs

**Vorgehen:**

1. Mit den eingerichteten Zugangsdaten anmelden.
2. Swagger UI und Endpoint `/triage` zeigen.
3. Auf „Try it out“ klicken.
4. Beispiel-Ticket senden:

```json
{
  "ticket_id": "demo-001",
  "subject": "Double charge on my invoice",
  "body": "I was charged twice for my insurance premium this month. Please refund the duplicate payment immediately."
}
```

**Sagen:**

„Der Agent analysiert das Ticket, erkennt Thema und Dringlichkeit und schlägt die nächste Bearbeitungsaktion vor. Die KI-Inferenz nutzt Amazon Bedrock. Externe Folgeaktionen werden in dieser Demo simuliert.“

**Wichtig:** Der öffentliche PROD-Stand enthält möglicherweise noch nicht alle neuen Inferenzmetadaten des DEV-Standes. Nur Felder erklären, die tatsächlich in der Response erscheinen.

## 3. Kubernetes und Namespaces (ca. 1 Minute)

**AWS-Terminal öffnen.**

```bash
kubectl get nodes
kubectl get namespaces
kubectl get pods -A -o wide
```

**Sagen:**

„Wir verwenden k3s auf einer AWS-EC2-Instanz. Die Anwendung ist logisch in Entwicklungs- und Produktivumgebung getrennt. Zusätzlich gibt es einen eigenen Monitoring-Namespace.“

**Dann zeigen:**

```bash
kubectl get deployments -n triage-dev
kubectl get deployments -n triage-prod
kubectl get pods -n triage-monitoring
```

**Sagen:**

„DEV und PROD laufen im selben Cluster, aber in unterschiedlichen Namespaces. Das erlaubt getrennte Deployments und Konfigurationen. Es sind keine physisch unabhängigen Cluster.“

## 4. Monitoring mit Grafana (ca. 1 Minute)

**Browser öffnen:**

https://grafana.automation-agent.ai/

**Vorgehen:**

1. Anmelden.
2. Dashboard „Ticket Triage — AWS DEV vs PROD“ öffnen.
3. Verfügbare Metriken und DEV-/PROD-Vergleich zeigen.

**Sagen:**

„Prometheus sammelt regelmäßig Anwendungsmetriken. Grafana visualisiert diese Metriken, sodass wir den Betriebszustand und die Umgebungen überwachen können.“

## 5. GitHub CI/CD zeigen (ca. 1–2 Minuten)

**Browser öffnen:**

https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions

**Vorgehen:**

1. Einen erfolgreichen CI-Lauf öffnen.
2. Tests, Container-Build und Security Scan zeigen.
3. Anschließend PR #3 öffnen:

https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/pull/3

**Sagen:**

„Unser CI-Prozess prüft automatisiert die Anwendung, erstellt ein Docker-Image, scannt es auf Sicherheitsprobleme und veröffentlicht es in der GitHub Container Registry.

Die erweiterte AWS-CD-Pipeline ist im Feature-Branch implementiert und validiert. Ihre automatische Aktivierung ist noch von IAM-, OIDC- und SSM-Voraussetzungen abhängig.“

**Nicht behaupten**, dass ein automatischer AWS-Rollout schon erfolgreich über diesen neuen Workflow erfolgt ist.

## 6. Backup-Automatisierung und Restore (ca. 1–2 Minuten)

**AWS-Terminal öffnen.**

**Timer anzeigen:**

```bash
sudo systemctl list-timers --all | grep liora
```

**Konfiguration zeigen:**

```bash
sudo systemctl cat liora-restic-backup.timer
```

**Letzten Backup-Lauf zeigen:**

```bash
sudo journalctl -u liora-restic-backup.service -n 25 --no-pager
```

**Sagen:**

„Unsere Datenbanken werden über einen systemd-Timer regelmäßig gesichert. Das Python-Skript prüft die Daten, anschließend erstellt Restic ein verschlüsseltes, inkrementelles Backup.“

**Wenn die finale EBS-Einrichtung erfolgreich abgeschlossen ist:**

Den vorhandenen Restic-Snapshot und das dokumentierte Restore-Testergebnis zeigen. Einen neuen Backup-Lauf nur starten, wenn die Konfiguration geprüft ist.

**Sagen:**

„Wir haben die Wiederherstellung getestet: 4.000 historische Tickets, 3.206 Vektoren und die Integrität der Dateien wurden überprüft.“

„Die Demo-Backups liegen lokal auf dem EBS-Volume. Eine externe S3-Sicherung ist als nächste Ausbaustufe vorgesehen und würde zusätzlich gegen Volume-Verlust schützen.“

## 7. Terraform Infrastructure as Code (ca. 45 Sekunden)

**In Cursor zeigen:**

`/home/ubuntu/workspaces/terraform-phase12d/`

**Sagen:**

„Die AWS-Infrastruktur wurde zusätzlich als Terraform-Konfiguration modelliert. Dazu gehören die GitHub-OIDC-Anbindung, IAM-Rollen und die Vorbereitung weiterer Infrastrukturkomponenten.

Die Terraform-Konfiguration ist validiert, wurde aber bewusst noch nicht auf die produktive AWS-Umgebung angewendet.“

## 8. Abschluss (ca. 30 Sekunden)

**Sagen:**

„Das Projekt zeigt den Weg vom lokalen KI-Prototyp zu einer Cloud-Native-Anwendung: containerisiert, auf Kubernetes betrieben, mit Amazon Bedrock integriert, überwacht und mit Backup- und CI/CD-Komponenten ergänzt.

Die nächsten Ausbauschritte sind die Aktivierung des automatischen AWS-Deployments sowie externe Backups und vollständige Disaster-Recovery-Tests.“

---

## Fallback bei technischen Problemen

**Swagger nicht erreichbar:** Architektur und bereits gespeicherte Testresponse zeigen.

**Kubernetes-Kommando funktioniert nicht:** `sudo k3s kubectl` als Alternative verwenden.

**Grafana nicht erreichbar:** Auf bereits vorhandene Dashboard-Screenshots zurückgreifen.

**GitHub Actions zeigt keinen neuen erfolgreichen Run:** Einen früheren erfolgreichen CI-Lauf zeigen und den aktuellen CD-Status korrekt einordnen.

**Backup-Timer nicht aktiv:** Die bestandenen lokalen Restic-Tests zeigen und die geplante Automatisierung ausdrücklich als noch nicht aktiv kennzeichnen.

**Grundregel:** Während der Defense keine Terraform-Applies, Git-Merges, PROD-Deployments oder riskanten Konfigurationsänderungen ausführen.