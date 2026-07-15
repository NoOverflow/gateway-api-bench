# Gateway API Benchmarks - Part 3

oc get validatingadmissionpolicybinding \
  openshift-ingress-operator-gatewayapi-crd-admission -o yaml > gateway-admission-binding.yaml

oc delete validatingadmissionpolicybinding \
  openshift-ingress-operator-gatewayapi-crd-admission

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml