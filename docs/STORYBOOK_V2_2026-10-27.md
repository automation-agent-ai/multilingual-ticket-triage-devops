# Liora DevOps Final Defense – Storybook V2

**Nikolaus Wrede · 27.10.2026**  
**Projekt:** AI Ticket Triage Agent – From Local Prototype to Cloud-Native Platform  
**Ziel:** 20 Minuten **inklusive** Live-Demonstration  
**Ablauf:** Folie → kurzer Sprechtext → passender Live-Nachweis → nächste Folie  
**Status:** Sprecher- und Demo-Drehbuch zur letzten Freigabe; keine produktiven Änderungen ausführen.

> **Hinweis zur Sprache:** Die „Sagen“-Texte bleiben bewusst auf Deutsch, wie im erfolgreichen Pre-Defense-Storybook. Die Folientitel und technischen Bezeichnungen bleiben Englisch. Bei Bedarf kann anschließend eine englische Sprecherfassung erstellt werden.

---

## 0. Die Geschichte in einem Satz

„Ich habe einen lokalen KI-Ticket-Triage-Prototyp zu einer auf AWS betriebenen, kontrolliert auslieferbaren und überwachbaren Cloud-Native-Anwendung weiterentwickelt – inklusive nachgewiesener Backups und erfolgreichem Daten-Restore.“

**Vier Fragen des Prüfers beantworten:**

1. **Was kann der Agent?** Tickets analysieren und strukturierte Handlungsempfehlungen liefern.
2. **Wo läuft er?** Docker/FastAPI auf AWS EC2 `m6i.xlarge` mit Single-Node-k3s; Inferenz über Amazon Bedrock Nova Micro.
3. **Wie kommt ein Release sicher in PROD?** Tests, Trivy, GHCR, automatisches DEV-Deployment und anschließend ausdrücklich freigegebene PROD-Promotion **desselben SHA-getaggten Images**.
4. **Wie wird die Plattform betrieben?** HTTPS/Tailscale, IAM/OIDC/SSM, Prometheus/Grafana, selektives Terraform-IaC und getesteter Daten-Restore mit Hetzner-Offsite-Backup.

**Nicht überverkaufen:** DEV/PROD sind Namespaces auf **einer** EC2-Instanz, nicht zwei hochverfügbare Cluster. Terraform verwaltet ausgewählte IAM-Ressourcen, nicht die gesamte EC2/k3s-Plattform. Der vollständige Plattform-DR-Prozess ist dokumentiert, aber **nicht end-to-end getestet**.

---

## 1. Opening – From Prototype to Cloud-Native Platform (0:30)

**Zeigen:** Titelfolie.

**Sagen:**

„Mein Ausgangspunkt war ein KI-Prototyp zur automatischen Klassifizierung von Support-Tickets. Die eigentliche DevOps-Frage war: Wie mache ich daraus einen Dienst, den ich reproduzierbar bauen, sicher ausliefern, überwachen und im Fehlerfall wiederherstellen kann? Genau diesen Weg zeige ich heute – mit einigen kurzen Live-Nachweisen.“

**Merken:** Ein Problem und ein Ergebnis; noch keine lange Technikliste.

**Übergang:** „Zuerst die Anwendung, die wir auf diese Plattform gebracht haben.“

---

## 2. Original AI Agent – Ausgangspunkt (0:50)

**Zeigen:** Vorhandene Folie mit ursprünglicher HDI-/Agent-Pipeline.

**Sagen:**

„Die Anwendung nimmt ein Ticket entgegen, validiert die Eingabe, nutzt Kontext und ein Sprachmodell, prüft die Ergebnisse und liefert eine strukturierte Empfehlung zurück: Thema, Dringlichkeit und nächste Aktion. Diese Trennung von Analyse, Validierung und Routing macht die Ergebnisse kontrollierbarer.“

**Auf der Folie mit dem Mauszeiger entlangfahren:** Input → Context/Retrieval → LLM → Validation → Routing.

**Wichtig:** Diese Folie zeigt die **ursprüngliche lokale Agentenarchitektur**. Auf AWS verwendet die laufende Anwendung **Amazon Bedrock Nova Micro**. Nicht behaupten, dass alle lokalen Modellkomponenten unverändert in AWS laufen.

**Übergang:** „Jetzt zur Infrastruktur, auf der der Service tatsächlich läuft.“

---

## 3. End-to-End Platform Architecture (1:10)

**Zeigen:** Aktualisierte Architekturfolie, inklusive Bullet **„Terraform: 4 IAM resources managed“**.

**Sagen:**

„Links beginnt alles im Developer Workspace. GitHub übernimmt Versionsverwaltung und CI/CD, danach läuft das Container-Image auf k3s in AWS. Bedrock liefert die Inferenz. Der öffentliche HTTPS-Zugriff erfolgt über einen Hetzner-Nginx-Gateway; dessen Verbindung zum AWS-Backend läuft privat über Tailscale. In der Plattform sind DEV, PROD und Monitoring logisch getrennt.“

**Kurz erläutern:**

- **GitHub / GHCR:** Quellcode und unveränderliches Release-Image.
- **AWS EC2 + k3s:** Ein Host, drei Namespaces: `triage-dev`, `triage-prod`, `triage-monitoring`.
- **Bedrock:** Nova Micro als Inferenzanbieter.
- **Hetzner Gateway:** HTTPS, Authentifizierung und privater Upstream.
- **Terraform:** Ausgewählte vier IAM-Ressourcen bereits verwaltet; der Umfang ist bewusst begrenzt.

**Keine lange Live-Demo hier:** Die Nachweise kommen an den folgenden Stellen.

**Übergang:** „Sehen wir uns kurz die AWS-Laufzeitumgebung an.“

---

## 4. AWS Runtime / Bedrock (0:50)

**Zeigen:** Bestehende AWS-Runtime- bzw. DEV-Folie.

**Sagen:**

„Die Anwendung läuft auf einer **EC2 m6i.xlarge** mit Ubuntu und einem schlanken **Single-Node-k3s**. Der FastAPI-Container nutzt Health- und Readiness-Prüfungen. Statt eines lokalen Ollama-Modells kommt **Amazon Bedrock Nova Micro** zum Einsatz; die AWS-Berechtigungen werden über eine IAM-Rolle bereitgestellt, ohne statische AWS-Keys im Anwendungscode.“

**Wichtig:** Die Folie entstand beim ersten AWS-DEV-Meilenstein. Inzwischen läuft die Anwendung **auch in PROD**. Angezeigte Performancewerte sind Momentaufnahmen, keine zugesicherten allgemeinen Antwortzeiten.

**Übergang:** „Wie genau gelangt eine neue Version nun automatisiert und kontrolliert auf diesen Server?“

---

## 5. CI/CD & Safe Release Flow + GitHub LIVE (2:40)

**Zeigen:** Neue CI/CD-Folie mit sieben Schritten, danach GitHub Actions im vorbereiteten Browser-Tab.

**Sagen (zunächst Folie):**

„Ein Push auf `main` startet die Validierung: pytest, Docker-Build und Trivy-Security-Scan. Nach erfolgreicher Prüfung veröffentlichen wir ein mit der Commit-SHA bezeichnetes Image in GHCR. Die AWS-DEV-Pipeline rollt es automatisch aus. Für PROD gibt es eine ausdrückliche manuelle GitHub-Environment-Freigabe. Entscheidend ist: **PROD erhält exakt dasselbe bereits getestete Image wie DEV.** Es wird bei der Promotion nicht neu gebaut oder gescannt.“

**LIVE – Tabs bereits öffnen, nur erfolgreiche Runs zeigen:**

1. [GitHub Actions](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions) → erfolgreicher [CI-Lauf](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40399921331).
2. Erfolgreicher [AWS DEV Deploy](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40399921485).
3. Erfolgreiche [PROD Promotion](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40405288664), Dauer laut dokumentiertem Lauf ca. **1:21**.

**Beweis zeigen:** Commit `05aa1fc…` und Image `aws-sha-05aa1fc…`.

**Sagen (Live-Nachweis):**

„Die drei grünen Läufe sind die Beweiskette: CI erfolgreich, DEV automatisch aktualisiert und PROD nach Freigabe ausgerollt. GitHub verwendet kurzlebige OIDC-Credentials und AWS SSM; wir hinterlegen dafür keine statischen AWS-Deployment-Keys.“

**Grenzen:** Die Freigabe ist explizit, aber nicht als unabhängiges Vier-Augen-Prinzip konfiguriert. Rollback-Mechanismus vorhanden; keinen erfolgreich getesteten PROD-Rollback behaupten. Während der Defense **keinen neuen Workflow auslösen**.

**Wenn GitHub langsam ist:** Bereits gespeicherte Screenshots der drei erfolgreichen Läufe zeigen; nach maximal 20 Sekunden weiter.

**Übergang:** „Jetzt prüfen wir, ob die freigegebene Version in Kubernetes tatsächlich läuft.“

---

## 6. Kubernetes Multi-Environment + Terminal LIVE (1:45)

**Zeigen:** Bestehende Kubernetes-/Multi-Environment-Folie, danach vorbereitete Cursor- oder SSH-Terminal-Session auf AWS.

**Sagen:**

„DEV, PROD und Monitoring sind unterschiedliche Kubernetes-Namespaces auf demselben k3s-Knoten. Sie besitzen eigene Deployments und Konfigurationen, nutzen aber für die Anwendung **dieselbe SHA-getaggte Container-Version**. Das ist logische Trennung, nicht physische Hochverfügbarkeit.“

**LIVE – nur read-only Befehle, möglichst als vorbereiteter Block:**

```bash
kubectl get nodes
kubectl get deploy,pods -n triage-dev
kubectl get deploy,pods -n triage-prod
kubectl get pods -n triage-monitoring
```

**Den zentralen Nachweis über das Image zeigen:**

```bash
kubectl get deployment ticket-triage -n triage-dev  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl get deployment ticket-triage -n triage-prod -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl rollout history deployment/ticket-triage -n triage-prod
```

**Sagen:**

„Hier sind beide Umgebungen. Das Image-Tag ist gleich. PROD war beim letzten technischen Check `1/1 Ready`, der Pod lief ohne Restarts. Die Rollout-History zeigt Revisionen; sie belegt keinen durchgeführten Rollback-Test.“

**Falls `kubectl` nicht gefunden:** `sudo k3s kubectl ...` verwenden. **Nicht** `kubectl apply`, `rollout undo` oder `delete` ausführen.

**Übergang:** „Damit läuft das Release – jetzt zeigen wir, was die API für ein echtes Ticket liefert.“

---

## 7. Ticket Triage – Swagger LIVE (3:20)

**Zeigen:** Vorhandene Live-Demo-Folie, dann [Swagger UI](https://triage.automation-agent.ai/docs).

**Voraussetzung:** HTTP Basic Auth am Hetzner-Gateway bereits vor dem Vortrag erfolgreich erledigt. Den aktuellen Endpoint und das OpenAPI-Request-Schema vorher testen.

**LIVE:**

1. API-Dokumentation zeigen, `POST /triage` (sofern aktueller Endpoint) aufklappen.
2. `Try it out` wählen.
3. Dieses Beispiel verwenden, **sofern es dem aktuellen Schema entspricht**:

```json
{
  "ticket_id": "demo-001",
  "subject": "Double charge on my invoice",
  "body": "I was charged twice for my insurance premium this month. Please refund the duplicate payment immediately."
}
```

4. `Execute` → Response-Code und strukturierte Antwort betrachten.
5. Nur tatsächlich sichtbare Felder zeigen und erklären (`topic`, `urgency`, `next_action`, `confidence`, soweit vorhanden).

**Sagen:**

„Ein reales Support-Ticket wird in ein strukturiertes Ergebnis übersetzt. Der Service erkennt beispielsweise ein Abrechnungsthema, bewertet die Dringlichkeit und empfiehlt eine nächste Aktion. Die Inferenz erfolgt über Bedrock Nova Micro. Die Struktur erlaubt nachgelagerte Qualitätskontrollen und automatisierte Weiterverarbeitung.“

**Wichtig:** Kein bestimmtes Confidence-Niveau versprechen. Bedrock-Metadaten nur erklären, wenn wirklich sichtbar. Keine tatsächliche E-Mail oder externe Ticketanlage behaupten; Folgeaktionen sind in dieser Demo ggf. simuliert.

**Fallback:** Nach ca. 30 Sekunden technischem Problem eine **vorbereitete und bereinigte Response** zeigen, statt Zeit im Browser zu verlieren.

**Übergang:** „Ein DevOps-System braucht nicht nur eine erfolgreiche Antwort; wir müssen seinen Betrieb überwachen.“

---

## 8. Observability – Prometheus & Grafana LIVE (2:00)

**Zeigen:** Bestehende Monitoring-Folie, dann [Grafana](https://grafana.automation-agent.ai/).

**Sagen:**

„Prometheus sammelt interne Anwendungs- und Laufzeitmetriken. Grafana visualisiert sie für DEV und PROD, etwa Request-Zahlen, Antwortzeiten und Fehler, sofern die Panels entsprechende Daten zeigen. So können wir Probleme erkennen und Deployments besser beobachten.“

**LIVE – priorisiert:**

1. Über vorbereitete Gateway- und Grafana-Authentifizierung das bestehende Dashboard öffnen.
2. Mindestens **ein Panel mit echten Daten** zeigen; z. B. Request Counts oder Latency.
3. Falls aktuell vorhanden, kurz DEV und PROD vergleichen, ohne unbelegte Performance-Vorteile zu behaupten.

**Optional nur bei Zeitreserve:** Prometheus-Targets über einen **vorher eingerichteten lokalen Port-Forward** zeigen. `/metrics` bleibt am öffentlichen Gateway absichtlich gesperrt.

**Sicherheitsnotiz:** Grafana nutzt Gateway Basic Auth plus eigenen Application Login. Neuere Dashboard-Änderungen aus einem noch nicht nach `main` deployten Arbeitsbranch nicht als bereits live darstellen.

**Fallback:** Screenshot eines funktionierenden Dashboards mit Datum/Status zeigen. Nicht mitten in der Defense Grafana neu konfigurieren.

**Übergang:** „Diese Sichtbarkeit ist bewusst hinter mehreren Zugangsschichten geschützt.“

---

## 9. Public HTTPS & Security (1:05)

**Zeigen:** Vorhandene Gateway-/Security-Folie.

**Sagen:**

„Ein öffentlicher HTTPS-Aufruf kommt zunächst beim Hetzner-Nginx-Gateway an. Dort greifen TLS und Basic Authentication. Über Tailscale geht die Verbindung privat zum AWS-Backend. Zusätzlich trennen wir Berechtigungen: GitHub Actions erhält temporäre AWS-Rechte via OIDC; die laufende Anwendung nutzt ihre AWS-IAM-Rolle. AWS SSM unterstützt das Deployment ohne feste SSH-Deployment-Keys.“

**Hervorheben:**

- **HTTPS/TLS** am öffentlichen Eingang.
- **Tailscale** als privater Netzwerkpfad.
- **Basic Auth**, bei Grafana zusätzlich Application Login.
- **Kein öffentliches `/metrics`**.
- **OIDC / IAM / SSM** für Deployment und Laufzeit.

**Nicht behaupten:** vollständiger Security-Audit, jede AWS-Portfreigabe ausgeschlossen oder unabhängiges Zwei-Personen-Approval.

**Übergang:** „Auch die Infrastrukturkonfiguration haben wir inzwischen in Code überführt – in einem klar abgegrenzten Umfang.“

---

## 10. Terraform & Infrastructure as Code (1:40)

**Zeigen:** Neue Terraform-Folie (DEFINE → IMPORT → REMOTE STATE → PLAN & VERIFY).

**Sagen:**

„Mit Terraform kann ich Infrastrukturzustände als Code dokumentieren und geplante Änderungen vorab prüfen. Wir haben **vier bereits existierende IAM-Ressourcen** in den Terraform-State importiert, also nicht neu erstellt. Der State ist remote abgelegt. Unser letzter verifizierter `terraform plan` ergab **No changes**: Für die von Terraform verwalteten Ressourcen hat es zu diesem Zeitpunkt keinen Drift gefunden.“

**Optionaler Nachweis (keine Infrastrukturmutation):** Vorbereiteten Screenshot der echten AWS-`terraform plan`-Ausgabe mit `No changes` zeigen. Nur wenn im richtigen Projektordner sicher vorbereitet, einen reinen Plan ausführen. **Nie `terraform apply` während der Defense.**

**Grenze unbedingt nennen:**

„Terraform verwaltet aktuell ausgewählte IAM-Bausteine. Wir können damit **noch nicht** die gesamte EC2-Instanz samt k3s und Gateway automatisch neu erstellen.“

**Übergang:** „Zum Schluss: Was passiert mit den Daten, wenn etwas ausfällt?“

---

## 11. Backup, Restore & Disaster Recovery (2:15)

**Zeigen:** Aktualisierte Backup-/DR-Folie mit den drei grünen bzw. bestätigten Status-Bereichen. Der siebenstufige Ablauf ist ausdrücklich **ein Recovery-Plan**.

**Sagen:**

„Ein **systemd Timer** startet täglich verschlüsselte Restic-Backups. Die Restic-Snapshots liegen auf einem AWS-EBS-Backup-Speicher. Automatisch werden sie per `restic copy` über Tailscale in ein separates Hetzner-Repository repliziert. Entscheidend ist: Wir haben die Anwendungsdaten aus einem Backup **isoliert wiederhergestellt** und DuckDB und LanceDB auf Integrität geprüft.“

**Zeigen – kurz und vorbereitet, keine Restore-Aktion auf PROD:**

```bash
sudo systemctl status liora-restic-backup.timer --no-pager
sudo journalctl -u liora-restic-backup.service -n 12 --no-pager
sudo journalctl -u liora-restic-offsite-copy.service -n 12 --no-pager
```

Danach ein bereits bereinigtes Beweisbild oder Testprotokoll des **isolierten DuckDB-/LanceDB-Restores**. Keine Backup-Passwörter, Tokens oder internen Geheimnisse zeigen.

**Unterscheidung unbedingt sagen:**

„Der Restore der **Applikationsdaten** wurde getestet. Der komplette Wiederaufbau von EC2, k3s, DNS und Hetzner-Gateway gemäß dem siebenstufigen Plan wurde dagegen **nicht Ende-zu-Ende getestet**.“

**Fachliche Präzision:** Es sind verschlüsselte **Restic-Snapshots auf EBS**, nicht zwingend native AWS-EBS-Snapshots. Kein aktives S3-Backupziel behaupten. Kein getesteter Kubernetes-PROD-Rollback behaupten.

**Übergang:** „Damit komme ich zu meinem Fazit.“

---

## 12. Closing (0:45, ohne neue Folie)

**Sagen:**

„Aus einem lokalen AI-Prototyp ist ein auf AWS betriebener Cloud-Native-Service geworden. Er lässt sich automatisiert testen und nach DEV ausliefern, kontrolliert nach PROD promoten, über Grafana beobachten und mit verifizierten Daten-Backups absichern. Die nächsten Ausbaustufen wären High Availability, mehr Terraform-Abdeckung und eine vollständige Disaster-Recovery-Übung. Für mich ist der wichtigste Fortschritt, dass wir jetzt echte, überprüfbare DevOps-Prozesse besitzen.“

**Danach:** „Thank you – I’m happy to take questions.“

---

## 13. Zeitplan – 20 Minuten inklusive Reserve

| Reihenfolge | Folie / Aktion | Budget | Kumuliert |
|---|---|---:|---:|
| 1 | Opening | 0:30 | 0:30 |
| 2 | Original AI Agent | 0:50 | 1:20 |
| 3 | End-to-End Architecture | 1:10 | 2:30 |
| 4 | AWS Runtime & Bedrock | 0:50 | 3:20 |
| 5 | CI/CD + GitHub Actions LIVE | 2:40 | 6:00 |
| 6 | k3s + kubectl LIVE | 1:45 | 7:45 |
| 7 | Swagger Ticket LIVE | 3:20 | 11:05 |
| 8 | Grafana LIVE | 2:00 | 13:05 |
| 9 | Security & Gateway | 1:05 | 14:10 |
| 10 | Terraform | 1:40 | 15:50 |
| 11 | Backup & Restore | 2:15 | 18:05 |
| — | Closing | 0:45 | **18:50** |
| — | Browserwechsel / Puffer | **1:10** | **20:00** |

**Zeitregel:** Falls du >60 Sekunden hinten liegst: Keine Prometheus-UI, keinen langen Terraform-Terminal-Lauf, GitHub auf die drei grünen Runs reduzieren. **Nicht kürzen:** die Produkt-Demo, die Identität des PROD-Images und die Unterscheidung „Daten-Restore getestet / vollständiger DR nicht getestet“.

---

## 14. Operator-Spickzettel vor der Defense

### Browser-Tabs in dieser Reihenfolge vorbereiten

1. Finale PowerPoint mit allen **11** Folien.
2. [GitHub Actions / CI](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40399921331).
3. [GitHub Actions / AWS DEV](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40399921485).
4. [GitHub Actions / PROD Promotion](https://github.com/automation-agent-ai/multilingual-ticket-triage-devops/actions/runs/40405288664).
5. [Swagger API](https://triage.automation-agent.ai/docs), mit vorbereitetem, zum Schema passendem Ticket.
6. [Grafana](https://grafana.automation-agent.ai/), Anmeldung vorab und funktionierendes Dashboard geöffnet.
7. AWS Terminal, **nur** lesende Kubernetes- und systemd-Abfragen bereitgelegt.
8. **Beleg-Screenshots:** AWS-Terraform-`plan: No changes`, Restic-Offsite-Kopie, isolierter Restore.

### Kritische Status-Checks vor Präsentationsbeginn

```bash
kubectl get deploy,pods -n triage-dev
kubectl get deploy,pods -n triage-prod
kubectl get pods -n triage-monitoring
sudo systemctl status liora-restic-backup.timer --no-pager
```

Auch prüfen: Swagger-Login und Testticket, Grafana-Login und ein mit Daten befülltes Panel; GitHub-Runs im Browser ladbar; Bildschirmskalierung und Terminal-Schriftgröße lesbar; keine Credentials im sichtbaren Fenster.

**Achtung Worktrees:** Das separate Grafana-Verbesserungsvorhaben auf Branch `fix/grafana-dashboard-g13` wurde zuletzt als **lokaler Commit** berichtet. Nicht behaupten, diese neue Version sei bereits live, solange Merge und Deployment nicht belegt sind. Die Defense kann das bisherige funktionierende Dashboard zeigen.

### Optional: Prometheus ohne öffentlichen Port (nur bei Zeitreserve)

Prometheus und das API-`/metrics` bleiben **intern**. Der öffentliche `/metrics`-Pfad wird vom Hetzner-Gateway bewusst blockiert.

```bash
# Terminal A auf AWS, laufen lassen
kubectl -n triage-monitoring port-forward svc/prometheus 19090:9090

# Localhost:19090 im Browser des Präsentationslaptops,
# wenn VS Code/Cursor Remote SSH diesen Port ebenfalls lokal weiterleitet.
# Alternativ: SSH -L mit bekanntem freigegebenem Host.
```

Die lokale `localhost`-Weiterleitung funktioniert nur auf dem **jeweiligen** Rechner, der den Tunnel erstellt hat; sie wird nicht automatisch auf andere Geräte übertragen.

### Credentials

Die alte private Referenzdatei war `~/.config/liora/demo-credentials.md` (Mode `0600`). Vor der Defense den **aktuellen** sicheren Speicherort und beide Authentifizierungsebenen prüfen. **Kein Passwort in Markdown, PowerPoint, Terminal-Aufzeichnung oder Screenshare offenlegen.**

---

## 15. Fallbacks – in 15 bis 30 Sekunden entscheiden

| Problem | Ruhige Alternative |
|---|---|
| Swagger/Bedrock antwortet nicht | Bereinigte, vorher aufgenommene Response zeigen, zum nächsten Punkt gehen |
| GitHub Actions langsam | Screenshots der erfolgreichen Runs und gleiche SHA zeigen |
| Kubernetes-Terminal nicht verbunden | Vorbereiteten Read-only-Output / Screenshot zeigen |
| Grafana leer oder Login scheitert | Letzten echten Dashboard-Screenshot zeigen, keine Live-Zahlen erfinden |
| Prometheus Port-Forward scheitert | Überspringen; Grafana reicht für den Monitoring-Nachweis |
| Terraform `plan` lokal nicht verfügbar | Verifizierten Screenshot mit `No changes` verwenden |
| Backup-Status nicht rechtzeitig abrufbar | Datierte Restic-/Restore-Evidence zeigen, keine neuen Restore-Kommandos |

### Während der Defense nicht ausführen

- Kein Git Merge/Push, kein neuer CI/CD-Run, keine manuelle PROD-Promotion.
- Kein `terraform apply`, `kubectl apply/delete/rollout undo` und keine Änderungen an IAM, DNS, Nginx oder AWS Security Groups.
- Keinen Restore auf PROD starten, keine Datenbank-Dateien überschreiben.
- Keine Backups/Passwörter/Schlüssel im Bildschirm teilen; Prometheus nicht öffentlich freigeben.

---

## 16. Was sich gegenüber `storybook(4).md` geändert hat

| Bereich | Alt | V2 |
|---|---|---|
| Zweck | Pre-Defense **nur Demo**, Ziel 8–12 Min, tatsächliche Summe ca. 14 Min | Ganze **11-Folien-Defense**, Vortrag + Live-Nachweise + Puffer = 20 Min |
| Erzählweise | Technologie-Blöcke begannen mit Swagger/Kubernetes | Reihenfolge der finalen Folien, Live-Beleg jeweils direkt zum Inhalt |
| AWS EC2 | `t3.medium` | `m6i.xlarge` |
| GitHub | AWS CD als noch in PR #3 / Feature-Branch | Erfolgreiche CI, automatisches DEV, freigegebenes PROD, **gleiches** Image |
| Terraform | Module vorbereitet, `apply` geplant | Remote State, vier bestehende IAM-Imports, letzter Plan **No changes** |
| Backup | Lokal + neuerer Offsite-Nachtrag, teils widersprüchliche Datierungen | EBS/Restic, Hetzner-`restic copy`, isolierter Restore **verifiziert** |
| DR-Grenze | Vollständige Wiederherstellung noch offen | Sichtbar und gesprochen: **Full platform DR plan NOT end-to-end tested** |
| Prometheus | Eigener längerer Live-Block und UI-Demo | Sicherer Port-Forward bleibt dokumentiert, aber **optional** (Zeitgewinn) |
| Sicherheit | HTTP Basic/Tailscale | Zusätzlich OIDC, IAM-Rolle, SSM sowie Freigabegrenze erläutert |
| Credentials | Private Referenz im alten Dokument | Keine Passwörter übernommen; Authentifizierung vorher vorbereiten |
| Betriebsrisiko | Einige aktive Demos möglich | Ausschließlich Read-only-Nachweise, klare 15–30-Sekunden-Fallbacks |

**Unverändert und bewusst bewahrt:** „Zeigen / Sagen“-Stil, einfaches Erklärungsvokabular, konkrete URLs, funktionierende Swagger-Beispielfrage, Namespaces, Security-Pfad, Backup-Timer, Terminal-Befehle und die bewährten Fallback-Prinzipien.

