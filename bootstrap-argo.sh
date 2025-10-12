helm repo add argo https://argoproj.github.io/argo-helm
helm install --version 7.6.8 --namespace argo-cd --create-namespace -f ./apps/argo-cd/values.yaml argo-cd argo/argo-cd

kubectl apply -f ./aoa.yaml