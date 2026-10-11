# ---------------------------------------------------------------------------
# Sprint S06 — Monitoring Infrastructure
#
# This module provisions the foundational Kubernetes resources that Sprint S07
# (Prometheus + Grafana deployment) will consume.  It manages ONLY the five
# resources listed below; it does not touch triage-dev or triage-prod.
# ---------------------------------------------------------------------------

# 1. Dedicated monitoring namespace
resource "kubernetes_namespace_v1" "triage_monitoring" {
  metadata {
    name = var.monitoring_namespace

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "multilingual-ticket-triage"
      "sprint"                       = "s06"
    }
  }
}

# 2. PersistentVolumeClaim for Prometheus time-series data
#
# Note: the 'standard' StorageClass on docker-desktop uses
# rancher.io/local-path with volumeBindingMode=WaitForFirstConsumer.
# The PVC will remain in Pending state until a Pod mounts it — this is
# expected and correct behaviour, NOT a failure.  Sprint S07 will deploy
# the Prometheus Pod that fulfils this claim.
resource "kubernetes_persistent_volume_claim_v1" "prometheus_data" {
  metadata {
    name      = "prometheus-data"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "prometheus"
      "sprint"                       = "s06"
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

  # The 'standard' StorageClass on docker-desktop uses volumeBindingMode=WaitForFirstConsumer.
  # The PVC stays Pending until Sprint S07's Prometheus Pod mounts it.
  # Setting wait_until_bound=false prevents Terraform from blocking on that binding.
  wait_until_bound = false
}

# 3. PersistentVolumeClaim for Grafana dashboard and plugin data
#
# Same WaitForFirstConsumer note applies — see comment on prometheus_data above.
resource "kubernetes_persistent_volume_claim_v1" "grafana_data" {
  metadata {
    name      = "grafana-data"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "grafana"
      "sprint"                       = "s06"
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

  # Same WaitForFirstConsumer note as prometheus_data above.
  wait_until_bound = false
}

# 4. ServiceAccount for Prometheus
#
# Sprint S07 will bind this ServiceAccount to a ClusterRole that allows
# Prometheus to scrape the Kubernetes API (/metrics, /pods, /endpoints).
resource "kubernetes_service_account_v1" "triage_prometheus" {
  metadata {
    name      = "triage-prometheus"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "prometheus"
      "sprint"                       = "s06"
    }
  }
}

# 5. ServiceAccount for Grafana
#
# Sprint S07 will configure Grafana to use this identity when querying
# the Kubernetes API for data-source discovery.
resource "kubernetes_service_account_v1" "triage_grafana" {
  metadata {
    name      = "triage-grafana"
    namespace = kubernetes_namespace_v1.triage_monitoring.metadata[0].name

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "grafana"
      "sprint"                       = "s06"
    }
  }
}
