#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# generate-runner-kubeconfig.sh
#
# Generates a scoped kubeconfig for the cicd-deployer ServiceAccount.
# The resulting file must be uploaded as the KUBECONFIG_DEV secret to the
# GitHub "dev" Environment and then deleted from disk immediately.
#
# Prerequisites:
#   kubectl apply -k k8s/runner/    # creates cicd-deployer + token Secret
#
# Usage:
#   bash scripts/generate-runner-kubeconfig.sh [output-path]
#
# Default output: runner-kubeconfig.yaml (current directory)
#
# Security notes:
#   • This script reads the SA token from the cluster at runtime.
#   • The output file contains a long-lived bearer token — treat as a secret.
#   • Upload to GitHub then delete locally: rm <output-path>
#   • Never commit the output file to git (it is listed in .gitignore).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SA_NAME="cicd-deployer"
NAMESPACE="triage-dev"
SECRET_NAME="cicd-deployer-token"
OUTPUT="${1:-runner-kubeconfig.yaml}"

echo "==> Generating scoped kubeconfig for ${SA_NAME}@${NAMESPACE}"

# Verify the token Secret exists (apply k8s/runner/ first)
if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Secret '${SECRET_NAME}' not found in namespace '${NAMESPACE}'."
  echo "Run first: kubectl apply -k k8s/runner/"
  exit 1
fi

# Extract token (base64-decoded)
TOKEN=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.data.token}' | base64 -d)

if [ -z "$TOKEN" ]; then
  echo "ERROR: Token is empty. The Secret may not have been populated yet."
  echo "Wait a few seconds and retry."
  exit 1
fi

# Extract cluster CA certificate (base64-encoded for embedding in kubeconfig)
CA_DATA=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.data.ca\.crt}')

# Cluster API server URL (from the current kubeconfig)
SERVER=$(kubectl config view --minify --output jsonpath='{.clusters[0].cluster.server}')

echo "==> Cluster server: ${SERVER}"
echo "==> CA cert length: ${#CA_DATA} chars"
echo "==> Token length:   ${#TOKEN} chars"

# Write the scoped kubeconfig
cat > "$OUTPUT" <<EOF
# ── SCOPED KUBECONFIG — triage-dev deployer ──
# ServiceAccount: ${SA_NAME} / Namespace: ${NAMESPACE}
# Permissions: deploy to triage-dev only (Role: cicd-deployer-role)
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# ⚠ SECURITY: This file contains a Kubernetes bearer token.
#   1. Upload it to GitHub: Settings → Environments → dev → Secrets → KUBECONFIG_DEV
#   2. Delete it immediately: rm ${OUTPUT}
#   3. Never commit to git.
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${SERVER}
  name: triage-dev-deployer
contexts:
- context:
    cluster: triage-dev-deployer
    namespace: ${NAMESPACE}
    user: ${SA_NAME}
  name: triage-dev-deployer
current-context: triage-dev-deployer
users:
- name: ${SA_NAME}
  user:
    token: ${TOKEN}
EOF

chmod 600 "$OUTPUT"

echo ""
echo "✅ Kubeconfig written to: ${OUTPUT}"
echo ""
echo "Next steps:"
echo "  1. cat '${OUTPUT}' | base64 -w0   (if your GH UI requires base64)"
echo "  2. Open: https://github.com/<ORG>/<REPO>/settings/environments"
echo "     → Environment: dev → Secrets → New secret"
echo "     → Name: KUBECONFIG_DEV, Value: (paste content of ${OUTPUT})"
echo "  3. Delete this file:  rm '${OUTPUT}'"
echo ""
echo "Verify access (before deleting):"
echo "  KUBECONFIG='${OUTPUT}' kubectl get deployments -n triage-dev"
echo ""
echo "⚠  Delete the file now. This token never expires unless you rotate it."
