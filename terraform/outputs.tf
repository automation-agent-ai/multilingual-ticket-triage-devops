output "monitoring_namespace" {
  description = "Name of the Terraform-managed monitoring namespace."
  value       = kubernetes_namespace_v1.triage_monitoring.metadata[0].name
}

output "prometheus_pvc_name" {
  description = "Name of the Prometheus PersistentVolumeClaim (consumed by Sprint S07)."
  value       = kubernetes_persistent_volume_claim_v1.prometheus_data.metadata[0].name
}

output "grafana_pvc_name" {
  description = "Name of the Grafana PersistentVolumeClaim (consumed by Sprint S07)."
  value       = kubernetes_persistent_volume_claim_v1.grafana_data.metadata[0].name
}

output "prometheus_service_account" {
  description = "Name of the Prometheus ServiceAccount (consumed by Sprint S07)."
  value       = kubernetes_service_account_v1.triage_prometheus.metadata[0].name
}

output "grafana_service_account" {
  description = "Name of the Grafana ServiceAccount (consumed by Sprint S07)."
  value       = kubernetes_service_account_v1.triage_grafana.metadata[0].name
}

output "storage_class" {
  description = "StorageClass used for both PVCs."
  value       = var.storage_class_name
}
