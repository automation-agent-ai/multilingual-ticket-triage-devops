output "namespace" {
  description = "Monitoring namespace name"
  value       = kubernetes_namespace_v1.triage_monitoring.metadata[0].name
}

output "prometheus_service" {
  description = "Prometheus service endpoint"
  value       = "http://${kubernetes_service_v1.prometheus.metadata[0].name}.${kubernetes_namespace_v1.triage_monitoring.metadata[0].name}.svc.cluster.local:9090"
}

output "grafana_service" {
  description = "Grafana service endpoint"
  value       = "http://${kubernetes_service_v1.grafana.metadata[0].name}.${kubernetes_namespace_v1.triage_monitoring.metadata[0].name}.svc.cluster.local:3000"
}

output "grafana_port_forward_command" {
  description = "Command to access Grafana via kubectl port-forward"
  value       = "kubectl port-forward -n ${kubernetes_namespace_v1.triage_monitoring.metadata[0].name} svc/${kubernetes_service_v1.grafana.metadata[0].name} 3000:3000"
}

output "prometheus_port_forward_command" {
  description = "Command to access Prometheus via kubectl port-forward"
  value       = "kubectl port-forward -n ${kubernetes_namespace_v1.triage_monitoring.metadata[0].name} svc/${kubernetes_service_v1.prometheus.metadata[0].name} 9090:9090"
}
