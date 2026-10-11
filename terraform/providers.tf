# Kubernetes provider configured to target the local docker-desktop cluster.
# The provider reads the kubeconfig at the standard WSL path and uses the
# explicit context name so it can never accidentally target another cluster
# (e.g. a remote Hetzner k3s context).
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}
