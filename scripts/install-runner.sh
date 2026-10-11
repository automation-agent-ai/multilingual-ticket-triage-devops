#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# install-runner.sh — Self-hosted GitHub Actions runner setup
#
# ⚠  DO NOT RUN THIS SCRIPT WITHOUT EXPLICIT USER APPROVAL.
#    Read docs/CICD.md §6 (Runner Security Analysis) before proceeding.
#
# What this script does:
#   1. Creates /home/niwr/actions-runner directory
#   2. Downloads the GitHub Actions runner binary (v2.321.0)
#   3. Verifies the SHA-256 checksum
#   4. Configures the runner against this repository
#   5. Installs it as a systemd service running as 'niwr'
#
# What it does NOT do:
#   • Does not mount /var/run/docker.sock (no Docker access)
#   • Does not install Docker in the runner environment
#   • Does not modify PROD manifests or cluster state
#   • Does not touch /home/niwr/workspaces other than reading this repo
#
# Prerequisites:
#   • kubectl apply -k k8s/runner/
#   • bash scripts/generate-runner-kubeconfig.sh
#   • KUBECONFIG_DEV uploaded to GitHub Environment "dev" secret
#   • GitHub registration token from:
#       https://github.com/<ORG>/<REPO>/settings/actions/runners/new
#
# Removal (full uninstall):
#   cd /home/niwr/actions-runner
#   sudo ./svc.sh stop
#   sudo ./svc.sh uninstall
#   ./config.sh remove --token <REMOVAL_TOKEN>
#   cd ~
#   rm -rf /home/niwr/actions-runner
#
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RUNNER_VERSION="2.338.0"
RUNNER_ARCH="linux-x64"
RUNNER_PKG="actions-runner-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_PKG}"
RUNNER_SHA256="af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32"

RUNNER_DIR="/home/niwr/actions-runner"
REPO_URL="https://github.com/automation-agent-ai/multilingual-ticket-triage-devops"
RUNNER_NAME="liora-dev-deployer-wsl2"
RUNNER_LABELS="self-hosted,linux,triage-dev-deployer"
RUNNER_WORK="${RUNNER_DIR}/_work"

# ── Safety guard ──────────────────────────────────────────────────────────────
if [ "${APPROVED:-}" != "yes" ]; then
  echo "ERROR: This script requires explicit approval."
  echo "Set APPROVED=yes to confirm you have read the security analysis in docs/CICD.md §6"
  echo "and you approve the runner installation."
  exit 1
fi

if [ -z "${GH_RUNNER_TOKEN:-}" ]; then
  echo "ERROR: Set GH_RUNNER_TOKEN to the GitHub registration token."
  echo "Get it from: ${REPO_URL}/settings/actions/runners/new"
  exit 1
fi

echo "==> Creating runner directory: ${RUNNER_DIR}"
mkdir -p "$RUNNER_DIR" "$RUNNER_WORK"

echo "==> Downloading runner v${RUNNER_VERSION}"
curl -sL "$RUNNER_URL" -o "/tmp/${RUNNER_PKG}"

echo "==> Verifying SHA-256 checksum"
echo "${RUNNER_SHA256}  /tmp/${RUNNER_PKG}" | sha256sum -c -
echo "Checksum OK"

echo "==> Extracting runner"
tar -xzf "/tmp/${RUNNER_PKG}" -C "$RUNNER_DIR"
rm "/tmp/${RUNNER_PKG}"

echo "==> Configuring runner"
cd "$RUNNER_DIR"
./config.sh \
  --url "$REPO_URL" \
  --token "$GH_RUNNER_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --work "$RUNNER_WORK" \
  --unattended

echo "==> Installing systemd service (requires sudo)"
sudo ./svc.sh install niwr
sudo ./svc.sh start

echo ""
echo "✅ Runner installed and started."
echo ""
echo "Verify in GitHub: ${REPO_URL}/settings/actions/runners"
echo "Check service:    sudo systemctl status actions.runner.*.service"
echo ""
echo "── Removal instructions ────────────────────────────────────────────────"
echo "  cd ${RUNNER_DIR}"
echo "  sudo ./svc.sh stop"
echo "  sudo ./svc.sh uninstall"
echo "  # Get removal token from GitHub: ${REPO_URL}/settings/actions/runners"
echo "  ./config.sh remove --token <REMOVAL_TOKEN>"
echo "  cd ~"
echo "  rm -rf ${RUNNER_DIR}"
