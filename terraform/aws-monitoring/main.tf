# ---------------------------------------------------------------------------
# AWS Monitoring Infrastructure for Multilingual Ticket Triage
#
# This Terraform configuration provisions Prometheus + Grafana monitoring
# on AWS EC2 k3s cluster for the DevOps pre-defense (October 13, 2026).
#
# Namespace: triage-monitoring
# Targets: triage-dev and triage-prod
# ---------------------------------------------------------------------------

# 1. Dedicated monitoring namespace
resource "kubernetes_namespace_v1" "triage_monitoring" {
  metadata {
    name = var.monitoring_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "multilingual-ticket-triage"
      "environment"                  = "aws-production"
    }
  }
}

# 2. PersistentVolumeClaim for Prometheus time-series data
resource "kubernetes_persistent_volume_claim_v1" "prometheus_data" {
  metadata {
    name      = "prometheus-data"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "prometheus"
    }
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class_name

    resources {
      requests = {
        storage = var.prometheus_pvc_size
      }
    }
  }

  # k3s local-path uses WaitForFirstConsumer - PVC will bind when pod starts
  wait_until_bound = false
}

# 3. PersistentVolumeClaim for Grafana data
resource "kubernetes_persistent_volume_claim_v1" "grafana_data" {
  metadata {
    name      = "grafana-data"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "grafana"
    }
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class_name

    resources {
      requests = {
        storage = var.grafana_pvc_size
      }
    }
  }

  wait_until_bound = false
}

# 4. ServiceAccount for Prometheus
resource "kubernetes_service_account_v1" "triage_prometheus" {
  metadata {
    name      = "triage-prometheus"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "prometheus"
    }
  }
}

# 5. ServiceAccount for Grafana
resource "kubernetes_service_account_v1" "triage_grafana" {
  metadata {
    name      = "triage-grafana"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "grafana"
    }
  }
}

# 6. Grafana admin credentials secret
resource "kubernetes_secret_v1" "grafana_credentials" {
  metadata {
    name      = "grafana-credentials"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "grafana"
    }
  }

  data = {
    admin-user     = var.grafana_admin_user
    admin-password = var.grafana_admin_password
  }

  type = "Opaque"
}

# 7. Prometheus configuration
resource "kubernetes_config_map_v1" "prometheus_config" {
  metadata {
    name      = "prometheus-config"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "prometheus"
    }
  }

  data = {
    "prometheus.yml" = <<-EOT
      global:
        scrape_interval: 30s
        evaluation_interval: 30s
        external_labels:
          cluster: 'aws-k3s'
          region: 'us-east-1'

      rule_files:
        - /etc/prometheus/rules/*.yaml

      scrape_configs:
        # Prometheus self-monitoring
        - job_name: 'prometheus'
          static_configs:
            - targets: ['localhost:9090']

        # Ticket Triage DEV
        - job_name: 'ticket-triage-dev'
          metrics_path: /metrics
          scrape_interval: 30s
          static_configs:
            - targets: ['ticket-triage.triage-dev.svc.cluster.local:8000']
          relabel_configs:
            - target_label: environment
              replacement: dev
            - target_label: app
              replacement: ticket-triage

        # Ticket Triage PROD
        - job_name: 'ticket-triage-prod'
          metrics_path: /metrics
          scrape_interval: 30s
          static_configs:
            - targets: ['ticket-triage.triage-prod.svc.cluster.local:8000']
          relabel_configs:
            - target_label: environment
              replacement: prod
            - target_label: app
              replacement: ticket-triage
    EOT
  }
}

# 8. Prometheus alert rules (minimal for demo)
resource "kubernetes_config_map_v1" "prometheus_rules" {
  metadata {
    name      = "prometheus-rules"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "prometheus"
    }
  }

  data = {
    "alerts.yaml" = <<-EOT
      groups:
        - name: ticket-triage
          interval: 30s
          rules:
            - alert: TicketTriageDown
              expr: up{job=~"ticket-triage.*"} == 0
              for: 2m
              labels:
                severity: critical
              annotations:
                summary: "Ticket Triage {{ $labels.job }} is down"
                description: "Target {{ $labels.job }} has been down for more than 2 minutes."

            - alert: HighErrorRate
              expr: rate(http_requests_total{status_code=~"5..", job=~"ticket-triage.*"}[5m]) > 0.01
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "High 5xx error rate in {{ $labels.job }}"
                description: "{{ $labels.job }} is returning {{ $value }} 5xx errors per second."
    EOT
  }
}

# 9. Prometheus Deployment
resource "kubernetes_deployment_v1" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/name"       = "prometheus"
      "app.kubernetes.io/component"  = "prometheus"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "prometheus"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "prometheus"
          "app.kubernetes.io/component" = "prometheus"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.triage_prometheus.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 65534
          run_as_group    = 65534
          fs_group        = 65534
        }

        container {
          name  = "prometheus"
          image = "prom/prometheus:v3.1.0"
          image_pull_policy = "IfNotPresent"

          args = [
            "--config.file=/etc/prometheus/prometheus.yml",
            "--storage.tsdb.path=/prometheus",
            "--storage.tsdb.retention.time=${var.prometheus_retention}",
            "--web.enable-lifecycle",
            "--web.console.libraries=/usr/share/prometheus/console_libraries",
            "--web.console.templates=/usr/share/prometheus/consoles"
          ]

          port {
            name           = "http"
            container_port = 9090
            protocol       = "TCP"
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
            read_only_root_filesystem = false
          }

          volume_mount {
            name       = "prometheus-data"
            mount_path = "/prometheus"
          }

          volume_mount {
            name       = "prometheus-config"
            mount_path = "/etc/prometheus/prometheus.yml"
            sub_path   = "prometheus.yml"
            read_only  = true
          }

          volume_mount {
            name       = "prometheus-rules"
            mount_path = "/etc/prometheus/rules"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/-/healthy"
              port = 9090
            }
            initial_delay_seconds = 30
            period_seconds        = 15
            failure_threshold     = 3
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/-/ready"
              port = 9090
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 6
            timeout_seconds       = 5
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "prometheus-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.prometheus_data.metadata[0].name
          }
        }

        volume {
          name = "prometheus-config"
          config_map {
            name = kubernetes_config_map_v1.prometheus_config.metadata[0].name
          }
        }

        volume {
          name = "prometheus-rules"
          config_map {
            name = kubernetes_config_map_v1.prometheus_rules.metadata[0].name
          }
        }

        restart_policy                   = "Always"
        termination_grace_period_seconds = 30
      }
    }
  }
}

# 10. Prometheus Service
resource "kubernetes_service_v1" "prometheus" {
  metadata {
    name      = "prometheus"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/name"       = "prometheus"
      "app.kubernetes.io/component"  = "prometheus"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app.kubernetes.io/name" = "prometheus"
    }

    port {
      name        = "http"
      port        = 9090
      target_port = 9090
      protocol    = "TCP"
    }
  }
}

# 11. Grafana datasource configuration
resource "kubernetes_config_map_v1" "grafana_datasources" {
  metadata {
    name      = "grafana-datasources"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "grafana"
    }
  }

  data = {
    "datasources.yaml" = <<-EOT
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          access: proxy
          url: http://prometheus.triage-monitoring.svc.cluster.local:9090
          isDefault: true
          editable: false
          uid: triage-prometheus
    EOT
  }
}

# 12. Grafana dashboard provider configuration
resource "kubernetes_config_map_v1" "grafana_dashboard_provider" {
  metadata {
    name      = "grafana-dashboard-provider"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "grafana"
    }
  }

  data = {
    "dashboards.yaml" = <<-EOT
      apiVersion: 1
      providers:
        - name: 'default'
          orgId: 1
          folder: ''
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards
    EOT
  }
}

# 13. Grafana dashboard - DEV vs PROD comparison
resource "kubernetes_config_map_v1" "grafana_dashboards" {
  metadata {
    name      = "grafana-dashboards"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "grafana"
    }
  }

  data = {
    "triage-comparison.json" = file("${path.module}/dashboards/triage-comparison.json")
  }
}

# 14. Grafana Deployment
resource "kubernetes_deployment_v1" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/name"       = "grafana"
      "app.kubernetes.io/component"  = "grafana"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "grafana"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "grafana"
          "app.kubernetes.io/component" = "grafana"
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.triage_grafana.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 472
          run_as_group    = 472
          fs_group        = 472
        }

        container {
          name  = "grafana"
          image = "grafana/grafana:11.4.0"
          image_pull_policy = "IfNotPresent"

          port {
            name           = "http"
            container_port = 3000
            protocol       = "TCP"
          }

          env {
            name = "GF_SECURITY_ADMIN_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.grafana_credentials.metadata[0].name
                key  = "admin-user"
              }
            }
          }

          env {
            name = "GF_SECURITY_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.grafana_credentials.metadata[0].name
                key  = "admin-password"
              }
            }
          }

          env {
            name  = "GF_AUTH_ANONYMOUS_ENABLED"
            value = "false"
          }

          env {
            name  = "GF_PATHS_PROVISIONING"
            value = "/etc/grafana/provisioning"
          }

          env {
            name  = "GF_ANALYTICS_REPORTING_ENABLED"
            value = "false"
          }

          env {
            name  = "GF_ANALYTICS_CHECK_FOR_UPDATES"
            value = "false"
          }

          env {
            name  = "GF_SERVER_ROOT_URL"
            value = "http://localhost:3000"
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
            read_only_root_filesystem = false
          }

          volume_mount {
            name       = "grafana-data"
            mount_path = "/var/lib/grafana"
          }

          volume_mount {
            name       = "grafana-datasources"
            mount_path = "/etc/grafana/provisioning/datasources"
            read_only  = true
          }

          volume_mount {
            name       = "grafana-dashboard-provider"
            mount_path = "/etc/grafana/provisioning/dashboards"
            read_only  = true
          }

          volume_mount {
            name       = "grafana-dashboards"
            mount_path = "/var/lib/grafana/dashboards"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/api/health"
              port = 3000
            }
            initial_delay_seconds = 30
            period_seconds        = 15
            failure_threshold     = 3
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/api/health"
              port = 3000
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            failure_threshold     = 6
            timeout_seconds       = 5
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "grafana-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.grafana_data.metadata[0].name
          }
        }

        volume {
          name = "grafana-datasources"
          config_map {
            name = kubernetes_config_map_v1.grafana_datasources.metadata[0].name
          }
        }

        volume {
          name = "grafana-dashboard-provider"
          config_map {
            name = kubernetes_config_map_v1.grafana_dashboard_provider.metadata[0].name
          }
        }

        volume {
          name = "grafana-dashboards"
          config_map {
            name = kubernetes_config_map_v1.grafana_dashboards.metadata[0].name
          }
        }

        restart_policy                   = "Always"
        termination_grace_period_seconds = 30
      }
    }
  }
}

# 15. Grafana Service
resource "kubernetes_service_v1" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/name"       = "grafana"
      "app.kubernetes.io/component"  = "grafana"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app.kubernetes.io/name" = "grafana"
    }

    port {
      name        = "http"
      port        = 3000
      target_port = 3000
      protocol    = "TCP"
    }
  }
}
