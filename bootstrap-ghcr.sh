#!/usr/bin/env bash
# Let the mini's k3s pull PRIVATE images from GHCR (ghcr.io/asherslab/*), for every namespace at once.
#
# Writes /etc/rancher/k3s/registries.yaml inside the Lima VM with a GitHub token, then restarts k3s so
# containerd picks it up. Node-level auth rather than an imagePullSecret per namespace: on a single node
# it is one credential in one place, and a new private app needs nothing but its manifests.
#
# The token never touches git, argv or the host's disk: it is read from the terminal and streamed into
# the VM over stdin. It lives on the VM's disk, so bootstrap-recreate-k3s.sh loses it — run this again
# after recreating the VM.
#
#   ./bootstrap-ghcr.sh                       # prompts for the token
#   GHCR_USER=asherslab ./bootstrap-ghcr.sh
#
# The token: a GitHub personal access token (classic) with ONLY the read:packages scope. Fine-grained
# tokens cannot read GHCR packages. Give it a long expiry and note the date — when it expires, pulls of
# new images fail with 401 (already-pulled images keep running).
#
# Idempotent: an unchanged file does not restart k3s.
set -euo pipefail

VM_NAME="${VM_NAME:-k3s}"
GHCR_USER="${GHCR_USER:-asherslab}"
CHECK_IMAGE="${CHECK_IMAGE:-ghcr.io/asherslab/graced-bibleapp:latest}"
TARGET=/etc/rancher/k3s/registries.yaml

fail() { echo "ERROR: $*" >&2; exit 1; }

command -v limactl >/dev/null || fail "lima not installed"
limactl list --format '{{.Status}}' "$VM_NAME" 2>/dev/null | grep -qx Running || fail "VM '$VM_NAME' is not running"
[[ -t 0 ]] || fail "run from a terminal: the token is read with a hidden prompt"

read -r -s -p "GitHub token for ${GHCR_USER} (read:packages): " TOKEN
echo
[[ -n "$TOKEN" ]] || fail "no token entered"

# Check the token against GHCR before touching the node, so a typo is an error here, not a restart.
# The credential goes to curl as a config on stdin (printf is a builtin), not as an argument `ps` can see.
REPO="${CHECK_IMAGE#ghcr.io/}"; REPO="${REPO%%:*}"
STATUS="$(printf 'user = "%s:%s"\n' "$GHCR_USER" "$TOKEN" | curl -s -K - -o /dev/null -w '%{http_code}' \
  "https://ghcr.io/token?scope=repository:${REPO}:pull")"
[[ "$STATUS" == "200" ]] || fail "GHCR rejected the token (HTTP $STATUS) — needs the read:packages scope"

CONTENT="$(cat <<EOF
# Written by gsbc.argo/bootstrap-ghcr.sh. Credentials for containerd image pulls; not in git.
configs:
  "ghcr.io":
    auth:
      username: ${GHCR_USER}
      password: ${TOKEN}
EOF
)"
unset TOKEN

# Compare without printing: only restart k3s when the file actually changes.
if printf '%s\n' "$CONTENT" | limactl shell "$VM_NAME" -- sudo sh -c "cmp -s - $TARGET"; then
  echo "==> $TARGET already up to date; k3s not restarted"
else
  echo "==> Writing $TARGET (mode 600) in VM '$VM_NAME'"
  printf '%s\n' "$CONTENT" | limactl shell "$VM_NAME" -- sudo install -m 600 -o root -g root /dev/stdin "$TARGET"
  echo "==> Restarting k3s (running pods keep running; the API blips for a few seconds)"
  limactl shell "$VM_NAME" -- sudo systemctl restart k3s
  limactl shell "$VM_NAME" -- sudo timeout 120 sh -c \
    'until k3s kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 2; done'
fi
unset CONTENT

echo "==> Test pull: $CHECK_IMAGE"
limactl shell "$VM_NAME" -- sudo k3s crictl pull "$CHECK_IMAGE" >/dev/null \
  && echo "OK — private GHCR images will pull." \
  || fail "pull failed; check: limactl shell $VM_NAME sudo journalctl -u k3s -n 50"
