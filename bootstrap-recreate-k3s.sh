#!/usr/bin/env bash
# DESTROY and rebuild the k3s Lima VM from scratch.
#
# The VM's disk holds the whole cluster: etcd/kine state, every container image,
# and every PersistentVolume (local-path stores PVCs inside the VM). Deleting the
# instance deletes all of it. There is no undo and no snapshot taken here.
#
# Use when a change cannot be applied to a running instance — vmType, arch, or a
# botched first boot. For anything else, prefer:
#   limactl stop k3s && limactl edit k3s && limactl start k3s
#
#   ./bootstrap-recreate-k3s.sh [--yes] [--param KEY=VALUE ...]
set -euo pipefail

VM_NAME="${VM_NAME:-k3s}"
ASSUME_YES=0
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1; shift ;;
    *)        PASSTHROUGH+=("$1"); shift ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }

command -v limactl >/dev/null || fail "lima not installed:  brew install lima"
[[ -x ./bootstrap-k3s.sh ]] || fail "./bootstrap-k3s.sh not found or not executable (run from the repo root)"

if ! limactl list --quiet 2>/dev/null | grep -qx "$VM_NAME"; then
  echo "==> No VM named '$VM_NAME'. Nothing to destroy; building fresh."
  exec ./bootstrap-k3s.sh ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
fi

# ---------- show what is about to be destroyed ----------
echo "About to DESTROY Lima instance '$VM_NAME':"
limactl list "$VM_NAME" || true
echo

# Best-effort inventory. If the cluster is reachable, name what dies with it —
# a count of PVCs is the difference between "empty VM" and "that was production".
if limactl list --format '{{.Status}}' "$VM_NAME" 2>/dev/null | grep -qx Running; then
  PVCS="$(limactl shell "$VM_NAME" -- sudo k3s kubectl get pvc -A --no-headers 2>/dev/null || true)"
  if [[ -n "$PVCS" ]]; then
    echo "PersistentVolumeClaims that will be destroyed:"
    echo "$PVCS" | awk '{printf "  %-16s %-34s %s\n", $1, $2, $4}'
    echo
    echo "!! Back these up first if they hold anything you need. !!"
    echo
  else
    echo "No PersistentVolumeClaims found in the cluster."
    echo
  fi
else
  echo "VM is not running — cannot inventory PVCs. Assume the disk holds data."
  echo
fi

# ---------- confirm ----------
if [[ "$ASSUME_YES" -ne 1 ]]; then
  if [[ ! -t 0 ]]; then
    fail "refusing to destroy '$VM_NAME' without a terminal; pass --yes if this is intentional"
  fi
  printf "Type the instance name (%s) to confirm destruction: " "$VM_NAME"
  read -r REPLY_NAME
  [[ "$REPLY_NAME" == "$VM_NAME" ]] || fail "confirmation did not match; nothing was deleted"
fi

# ---------- destroy ----------
echo "==> Stopping '$VM_NAME'"
limactl stop "$VM_NAME" 2>/dev/null || limactl stop --force "$VM_NAME" 2>/dev/null || true

echo "==> Deleting '$VM_NAME'"
limactl delete --force "$VM_NAME"

# ---------- rebuild ----------
echo "==> Rebuilding"
exec ./bootstrap-k3s.sh ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
