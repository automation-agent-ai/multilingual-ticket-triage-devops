variable "kubeconfig_path" {
  description = "Absolute path to the kubeconfig file used by the Kubernetes provider."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubernetes context name. Must be 'docker-desktop' for this local cluster."
  type        = string
  default     = "docker-desktop"
}

variable "monitoring_namespace" {
  description = "Namespace that will host Prometheus, Grafana and related monitoring resources."
  type        = string
  default     = "triage-monitoring"
}

variable "storage_class_name" {
  description = "StorageClass used for PVC provisioning. Defaults to the cluster default ('standard' on docker-desktop)."
  type        = string
  default     = "standard"
}

variable "prometheus_pvc_size" {
  description = "Size of the Prometheus data PersistentVolumeClaim."
  type        = string
  default     = "1Gi"
}

variable "grafana_pvc_size" {
  description = "Size of the Grafana data PersistentVolumeClaim."
  type        = string
  default     = "1Gi"
}
