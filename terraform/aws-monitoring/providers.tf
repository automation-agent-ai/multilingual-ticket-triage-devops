# Kubernetes provider configured to target the AWS k3s cluster.
# Reads the default kubeconfig and uses the "default" context which points
# to the AWS k3s cluster (verified during inventory phase).
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "default"
}
