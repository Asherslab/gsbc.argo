#!/usr/bin/env bash
# Provision the single-node k3s cluster on the Mac mini and wire up kubectl.
# Run on the mini. Idempotent.
#
# Static addressing lives in the `param:` block of lima-k3s.yaml. Override
# without editing the file:
#   ./bootstrap-k3s.sh --param LAN_CIDR=10.0.0.50/24 --param LAN_GATEWAY=10.0.0.1
set -euo pipefail

VM_NAME="${VM_NAME:-k3s}"
CONTEXT_NAME="${CONTEXT_NAME:-mini}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/config-mini}"

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------- preflight ----------
command -v limactl >/dev/null || fail "lima not installed:  brew install lima"
command -v qemu-system-aarch64 >/dev/null || fail "qemu not installed:  brew install qemu"

SOCKET_VMNET=/opt/socket_vmnet/bin/socket_vmnet
if [[ ! -x "$SOCKET_VMNET" ]]; then
  cat >&2 <<EOF
ERROR: socket_vmnet not found at $SOCKET_VMNET

Bridged networking needs it, and it must live somewhere only root can replace
(it is invoked via sudo). Homebrew's prefix is user-writable, so build from source:

  git clone https://github.com/lima-vm/socket_vmnet && cd socket_vmnet
  git checkout v1.2.2
  make && sudo make PREFIX=/opt/socket_vmnet install.bin
EOF
  exit 1
fi

NETWORKS_YAML="$HOME/.lima/_config/networks.yaml"
if ! grep -qE '^\s+bridged:' "$NETWORKS_YAML" 2>/dev/null; then
  cat >&2 <<EOF
ERROR: no 'bridged' network defined in $NETWORKS_YAML

Add it, setting 'interface' to the mini's WIRED port — bridging over Wi-Fi is
unreliable; confirm the name with: networksetup -listallhardwareports

  networks:
    bridged:
      mode: bridged
      interface: en0

Then generate the sudoers file — IN THIS ORDER, networks.yaml first, or limactl
will report the sudoers file as out of sync:

  limactl sudoers > /tmp/lima.sudoers
  less /tmp/lima.sudoers          # read it before installing it
  sudo install -o root -m 0440 /tmp/lima.sudoers /etc/sudoers.d/lima
  rm /tmp/lima.sudoers
EOF
  exit 1
fi

[[ -f /etc/sudoers.d/lima ]] || fail "/etc/sudoers.d/lima missing — see 'limactl sudoers' step above"

# ---------- vm ----------
if limactl list --quiet 2>/dev/null | grep -qx "$VM_NAME"; then
  CURRENT_TYPE="$(limactl list --format '{{.VMType}}' "$VM_NAME" 2>/dev/null || true)"
  if [[ -n "$CURRENT_TYPE" && "$CURRENT_TYPE" != "qemu" ]]; then
    fail "VM '$VM_NAME' exists with vmType=$CURRENT_TYPE. vmType is immutable; bridged networking needs qemu.
       Recreate it:  limactl delete --force $VM_NAME  &&  $0"
  fi
  echo "==> VM '$VM_NAME' exists; starting if stopped"
  limactl start "$VM_NAME"
else
  echo "==> Creating VM '$VM_NAME'"
  limactl start --name="$VM_NAME" --tty=false "$@" ./lima-k3s.yaml
fi

# ---------- kubeconfig ----------
# k3s writes server: https://127.0.0.1:6443, which lima auto-forwards to the host.
echo "==> Exporting kubeconfig to $KUBECONFIG_OUT"
mkdir -p "$(dirname "$KUBECONFIG_OUT")"
limactl cp "$VM_NAME:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_OUT"
chmod 600 "$KUBECONFIG_OUT"

# Rename via kubectl, not sed: k3s writes the users entry as "- name: default"
# and the cluster/context entries as "  name: default", so line-oriented
# rewriting silently desyncs the context's user reference from the user entry.
if KUBECONFIG="$KUBECONFIG_OUT" kubectl config get-contexts -o name | grep -qx default; then
  KUBECONFIG="$KUBECONFIG_OUT" kubectl config rename-context default "$CONTEXT_NAME" >/dev/null
fi
KUBECONFIG="$KUBECONFIG_OUT" kubectl config use-context "$CONTEXT_NAME" >/dev/null

# ---------- verify ----------
echo "==> Verifying"
export KUBECONFIG="$KUBECONFIG_OUT"
kubectl get nodes -o wide
kubectl get storageclass

NODE_IP="$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"

cat <<EOF

Done.
  export KUBECONFIG=$KUBECONFIG_OUT

Node is on the LAN at ${NODE_IP}. The API server carries a SAN for it, so from
any machine on the LAN you can point kubectl at https://${NODE_IP}:6443 instead
of tunnelling through the mini's loopback forward.

Next steps:
  1. Install the LaunchAgent:
       cp au.adp.lima-k3s.plist ~/Library/LaunchAgents/
       launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/au.adp.lima-k3s.plist
  2. Bootstrap Argo CD against clusters/mini.
EOF
