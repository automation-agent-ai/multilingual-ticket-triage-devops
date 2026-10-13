variable "monitoring_namespace" {
  description = "Kubernetes namespace for monitoring stack"
  type        = string
  default     = "triage-monitoring"
}

variable "storage_class_name" {
  description = "StorageClass for PersistentVolumeClaims (k3s uses local-path)"
  type        = string
  default     = "local-path"
}

variable "prometheus_pvc_size" {
  description = "Storage size for Prometheus time-series database"
  type        = string
  default     = "10Gi"
}

variable "prometheus_retention" {
  description = "Prometheus data retention period"
  type        = string
  default     = "7d"
}

variable "grafana_pvc_size" {
  description = "Storage size for Grafana data"
  type        = string
  default     = "2Gi"
}

variable "grafana_admin_user" {
  description = "Grafana admin username"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}
