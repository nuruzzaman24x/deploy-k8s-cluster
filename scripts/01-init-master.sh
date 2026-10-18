#!/usr/bin/env bash
#
# 01-init-master.sh
# ------------------------------------------------------------------
# Bootstraps the Kubernetes CONTROL-PLANE (master) node with kubeadm.
# All topology/version values come from ../config.env — edit that
# file, not this script, to point at different IPs or versions.
#
# Run as root ON THE MASTER NODE ONLY:
#   sudo ./01-init-master.sh
# ------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.env
source "${SCRIPT_DIR}/../config.env"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_root

log "Starting control-plane init for '${MASTER_HOSTNAME}' (${MASTER_IP})"
log "Kubernetes v${K8S_VERSION} | CRI-O ${CRIO_VERSION} | Pod CIDR ${POD_CIDR}"

check_arch
maybe_install_vmware_tools
preflight_resource_check
disable_swap
configure_kernel_and_sysctl
configure_hosts_file
install_crio
install_kube_tools
install_nfs_common

log "Running kubeadm init"
kubeadm init \
  --apiserver-advertise-address="${MASTER_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --kubernetes-version="v${K8S_VERSION}" \
  --node-name="${MASTER_HOSTNAME}" \
  --cri-socket=unix:///var/run/crio/crio.sock \
  --upload-certs

log "Configuring kubeconfig"
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config

REAL_USER="${SUDO_USER:-}"
if [[ -n "${REAL_USER}" ]]; then
  REAL_HOME=$(getent passwd "${REAL_USER}" | cut -d: -f6)
  mkdir -p "${REAL_HOME}/.kube"
  cp -i /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
  chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.kube/config"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

log "Installing Flannel CNI"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# CRI-O ships a default bridge CNI config that can conflict with Flannel's.
# Clear it if present so Flannel is the only CNI plugin in effect.
if ls /etc/cni/net.d/*crio-bridge* >/dev/null 2>&1; then
  log "Removing CRI-O's default bridge CNI config (conflicts with Flannel)"
  rm -f /etc/cni/net.d/*crio-bridge* /etc/cni/net.d/*loopback*
fi

log "Waiting for the control-plane node to become Ready (up to ~3 min)"
for _ in $(seq 1 36); do
  if kubectl get nodes 2>/dev/null | grep -q " Ready "; then
    break
  fi
  sleep 5
done
kubectl get nodes -o wide || true

echo ""
echo "=================================================================="
echo " Control-plane init complete."
echo " Saving the worker join command to /root/kubeadm-join-command.sh"
echo "=================================================================="
kubeadm token create --print-join-command > /root/kubeadm-join-command.sh
chmod 700 /root/kubeadm-join-command.sh
cat /root/kubeadm-join-command.sh

# Pull just the token and CA hash back out for convenience, since
# 02-join-worker.sh takes them as its own arguments (MASTER_IP comes
# from config.env on the worker, not from this output).
TOKEN=$(grep -oP '(?<=--token )\S+' /root/kubeadm-join-command.sh)
HASH=$(grep -oP '(?<=--discovery-token-ca-cert-hash )\S+' /root/kubeadm-join-command.sh)

echo ""
echo "On each worker (after copying this repo + config.env there), run:"
echo ""
echo "  sudo ./02-join-worker.sh ${TOKEN} ${HASH}"
echo ""
