#!/usr/bin/env bash
# Install Argo CD and hand it the app-of-apps for one cluster.
#   ./bootstrap-argo.sh mini
#   ./bootstrap-argo.sh oci
set -euo pipefail

CLUSTER="${1:-}"
[[ -n "$CLUSTER" ]] || { echo "usage: $0 <mini|oci>" >&2; exit 1; }
[[ -d "clusters/$CLUSTER" ]] || { echo "ERROR: no clusters/$CLUSTER" >&2; exit 1; }

echo "==> Target context: $(kubectl config current-context)"
read -r -p "Install Argo CD for '$CLUSTER' into that cluster? [y/N] " ok
[[ "$ok" == "y" ]] || exit 1

VALUES=(-f ./apps/argo-cd/values.yaml)
[[ -f "./clusters/$CLUSTER/values/argo-cd.yaml" ]] && VALUES+=(-f "./clusters/$CLUSTER/values/argo-cd.yaml")

helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argo-cd argo/argo-cd \
  --version 8.6.0 \
  --namespace argo-cd --create-namespace \
  "${VALUES[@]}"

# Wait for the repo-server to accept connections before handing Argo the aoa app.
# Otherwise the first reconcile records a ComparisonError against a repo-server
# that was still binding its port, and the app sits in Unknown until refreshed.
kubectl -n argo-cd rollout status deploy/argo-cd-argocd-repo-server --timeout=180s

kubectl apply -f "./clusters/$CLUSTER/aoa.yaml"
