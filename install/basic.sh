#!/bin/bash

WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)

# Only used for openshift
oc scale -n openshift-ingress-operator deployment.apps/ingress-operator --replicas=0
oc delete validatingadmissionpolicybinding openshift-ingress-operator-gatewayapi-crd-admission
oc delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io

# Note: required for https://github.com/agentgateway/agentgateway/issues/2370
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml --server-side --force-conflicts

# Note: I haven't found a reliable way to disable the securityContext, manual update is needed here for openshift.
helm upgrade --install --create-namespace --namespace envoy-gateway-system --version v1.8.2 eg oci://docker.io/envoyproxy/gateway-helm \
  --set config.envoyGateway.provider.kubernetes.deploy.type=GatewayNamespace \
  --set deployment.envoyGateway.resources.limits.memory=null \
  --set crds.enabled=false \
  --set certgen.job.securityContext.runAsUser=1000950000 \
  --set deployment.envoyGateway.securityContext.runAsUser=1000950000


helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
    --create-namespace --namespace agentgateway-system \
    --version v1.3.1 \
    --set controller.image.pullPolicy=Always

# Enable Alpha APIs for ListenerSet testing
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system \
  --version v1.3.1 \
  --set controller.image.pullPolicy=Always \
  --set inferenceExtension.enabled=true \
  --wait

cat <<EOF | helm upgrade --install istiod --create-namespace --namespace istio-system --version 1.30.2 https://istio-release.storage.googleapis.com/charts -f -
global:
  proxy:
    resources:
      limits: null # disable limits to match other gateways
autoscaleEnabled: false # disable autoscaling for more consistent tests
env: # Needed for ListenerSet testing
  PILOT_ENABLE_ALPHA_GATEWAY_API: true
EOF

helm upgrade --install nginx --namespace nginx-system --create-namespace --version 2.6.6 oci://ghcr.io/nginx/charts/nginx-gateway-fabric

kubectl create namespace monitoring
kubectl apply -f "${WD}/prometheus.yaml"
kubectl apply -f "${WD}/grafana.yaml"
kubectl apply -f "${WD}/metrics-server.yaml"

kubectl create namespace istio
kubectl create namespace envoy
kubectl create namespace agentgateway
kubectl create namespace nginx
kubectl create namespace haproxy
kubectl apply -f "${WD}/gateways.yaml"
