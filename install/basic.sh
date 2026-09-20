#!/bin/bash

WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)

# Note: dirty fix for CRC limited service CIDR
if ! kubectl get servicecidr gateway-api-bench >/dev/null 2>&1; then
  for _ in $(seq 1 40); do
    kubectl delete validatingadmissionpolicybinding servicecidrs-binding --wait=false >/dev/null 2>&1
    kubectl apply -f "${WD}/service-cidr.yaml" 2>/dev/null && break
  done
  kubectl wait --for=condition=Ready servicecidr/gateway-api-bench --timeout=60s
fi

# Only used for openshift
oc scale -n openshift-ingress-operator deployment.apps/ingress-operator --replicas=0
oc delete validatingadmissionpolicybinding openshift-ingress-operator-gatewayapi-crd-admission
oc delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io

# Note: required for https://github.com/agentgateway/agentgateway/issues/2370
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/experimental-install.yaml --server-side --force-conflicts

# Note: I haven't found a reliable way to disable the securityContext, manual update is needed here for openshift.
# OpenShift only: custom SCC allowing the envoy pods' pinned UID, NET_BIND_SERVICE and seccomp profile.
kubectl apply -f "${WD}/envoy-scc.yaml"

# The Envoy Gateway CRD chart is too large for a Helm release Secret (>1MiB), so
# render it and apply the CRDs directly.
kubectl create namespace envoy-gateway-system --dry-run=client -o yaml | kubectl apply -f -
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version v1.9.1 \
  --namespace envoy-gateway-system \
  --set crds.envoyGateway.enabled=true \
  --set crds.gatewayAPI.enabled=false | kubectl apply --server-side --force-conflicts -f -

helm upgrade --install --create-namespace --namespace envoy-gateway-system --version v1.9.1 eg oci://docker.io/envoyproxy/gateway-helm \
  --set config.envoyGateway.provider.kubernetes.deploy.type=GatewayNamespace \
  --set deployment.envoyGateway.resources.limits.memory=null \
  --set crds.enabled=false \
  --set certgen.job.securityContext.runAsUser=1000950000 \
  --set deployment.envoyGateway.securityContext.runAsUser=1000950000


# OpenShift only: custom SCC allowing the agentgateway proxy pods' pinned UID
# (10101, outside the namespace's restricted-v2 range) plus NET_BIND_SERVICE.
kubectl apply -f "${WD}/agentgateway-scc.yaml"
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
    --create-namespace --namespace agentgateway-system \
    --version v1.5.0 \
    --set controller.image.pullPolicy=Always

# Enable Alpha APIs for ListenerSet testing
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system \
  --version v1.5.0 \
  --set controller.image.pullPolicy=Always \
  --set inferenceExtension.enabled=true \
  --wait

# Istio 1.31+ charts are published as OCI artifacts on ghcr.io (the GCS helm repo
# is being retired and does not carry 1.31.0).
# Install the istio base chart for the networking.istio.io CRDs (e.g.
# DestinationRule, used by the backendfailover test's outlier-detection variant).
helm upgrade --install istio-base --create-namespace --namespace istio-system --version 1.31.0 oci://ghcr.io/istio/release/charts/base
cat <<EOF | helm upgrade --install istiod --create-namespace --namespace istio-system --version 1.31.0 oci://ghcr.io/istio/release/charts/istiod -f -
global:
  proxy:
    resources:
      limits: null # disable limits to match other gateways
      requests: null # avoid reserving different dataplane capacity per gateway
autoscaleEnabled: false # disable autoscaling for more consistent tests
env: # Needed for ListenerSet testing
  PILOT_ENABLE_ALPHA_GATEWAY_API: true
EOF

# NGF requires its CRDs to be applied out-of-band before installing/upgrading the chart.
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.7.2/deploy/crds.yaml
helm upgrade --install nginx --namespace nginx-system --create-namespace --version 2.7.2 oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --set nginx.service.type=NodePort

helm repo add haproxytech https://haproxytech.github.io/helm-charts
helm repo update
# OpenShift only: custom SCC allowing the haproxy pod's UID 1000, NET_BIND_SERVICE and seccomp profile.
kubectl apply -f "${WD}/haproxy-scc.yaml"
# The proxy runs as non-root and OpenShift's default net.ipv4.ip_unprivileged_port_start=1024
# blocks binding the port 80 listener (marking it Invalid), so lower it via the safe sysctl.
# controller.resources.limits is cleared: the chart pins a 2560Mi memory limit,
# but the benchmarks want no limits so the proxy is never throttled/OOM-killed.
# crdjob installs/updates the gate.v3.haproxy.org CRDs (the chart has no crds/ dir);
# gwapijob is disabled because the Gateway API CRDs are installed above.
helm upgrade  --install haproxy --namespace haproxy-system --create-namespace haproxytech/haproxy-unified-gateway --set gwapijob.enabled=false --set crdjob.enabled=true --set hugconf.create=false --set controller.service.type=NodePort --set-json 'controller.podSecurityContext.sysctls=[{"name":"net.ipv4.ip_unprivileged_port_start","value":"0"}]' --set 'controller.resources.limits=null' --set 'controller.resources.requests=null' --version 1.2.0

kubectl create namespace monitoring
kubectl apply -f "${WD}/prometheus.yaml"
kubectl apply -f "${WD}/grafana.yaml"
# victoria-logs: sink for the load tests' per-request results (see tests/common.sh
# log-flag), and Grafana's VictoriaLogs datasource points at it.
kubectl apply -f "${WD}/victoria.yaml"
kubectl apply -f "${WD}/metrics-server.yaml"

kubectl create namespace istio
kubectl create namespace envoy
kubectl create namespace agentgateway
kubectl create namespace nginx
kubectl create namespace haproxy
kubectl apply -f "${WD}/gateways.yaml"
