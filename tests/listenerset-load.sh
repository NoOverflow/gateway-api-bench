#!/bin/bash
WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)
source "$WD/common.sh"

namespaces="${1:-10}"
routes="${2:-100}"

if [[ -z "$PILOT_LOAD_BIN" ]]; then
  echo "pilot-load is required; set PILOT_LOAD_BIN or add it to PATH" >&2
  exit 1
fi

# Only implementations that accept ListenerSets are loaded (HAProxy leaves them
# Pending). The Gateways must set spec.allowedListeners (see install/gateways.yaml)
# or every ListenerSet is rejected as NotAllowed. Override with
# LISTENERSET_GATEWAYS=ns/name,ns/name.
if [[ -n "${LISTENERSET_GATEWAYS:-}" ]]; then
  IFS=',' read -r -a ls_gateways <<< "$LISTENERSET_GATEWAYS"
else
  ls_gateways=(agentgateway/agentgateway envoy/envoy-gateway istio/istio nginx/nginx)
fi

mesh_namespaces() {
  if (( namespaces <= 1 )); then
    echo "mesh"
  else
    local r
    for (( r = 0; r < namespaces; r++ )); do echo "mesh-0-${r}"; done
  fi
}

# pilot-load's builtin tls-secret template renders an Opaque Secret. Nginx
# Gateway Fabric rejects it (InvalidCertificateRef) and Envoy Gateway accepts
# the ListenerSet without programming it, so generate two proper
# kubernetes.io/tls Secrets (pilot-load alternates between them to simulate
# certificate rotation).
CERT_DIR="$(mktemp -d)"
trap 'rm -rf "$CERT_DIR"' EXIT
for i in a b; do
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
    -keyout "$CERT_DIR/$i.key" -out "$CERT_DIR/$i.crt" -subj "/CN=listenerset-$i.example.com" >/dev/null 2>&1
done
indent() { sed 's/^/        /' "$1"; }
CERT_A="$(indent "$CERT_DIR/a.crt")"; KEY_A="$(indent "$CERT_DIR/a.key")"
CERT_B="$(indent "$CERT_DIR/b.crt")"; KEY_B="$(indent "$CERT_DIR/b.key")"

run_pilot_load() {
  if [[ -n "${RUN_DURATION:-}" ]]; then
    timeout --foreground "$RUN_DURATION" "$PILOT_LOAD_BIN" cluster --config -
    local rc=$?
    [[ $rc -eq 124 ]] && return 0
    return "$rc"
  fi
  "$PILOT_LOAD_BIN" cluster --config -
}

# Scale tests own these namespaces. Remove any asynchronously deleted namespace
# from a prior run before asking pilot-load to create it again.
wait_for_teardown() {
  local ns
  for ns in mesh $(mesh_namespaces); do
    kubectl wait --for=delete "namespace/${ns}" --timeout=180s >/dev/null 2>&1 || \
      kubectl delete namespace "$ns" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 || true
  done
}

run_load() {
  local target="${1:-}"
  local gateway_list="" gw
  for gw in "$@"; do
    gateway_list+="          - ${gw}"$'\n'
  done
  wait_for_teardown
  local run_start run_end
  run_start="$(date +%s)"
  cat <<EOF | run_pilot_load
jitter:
  workloads: "2s"
  config: "1s"
gracePeriod: 500ms
stableNames: true
namespaces:
  - name: mesh
    replicas: ${namespaces}
    configs:
    - name: tls-secret
      config:
        Name: ns-cert
    applications:
    - name: app
      replicas: ${routes}
      pods: 1
      type: plain
      configs:
      - name: route
        config:
          gateways:
${gateway_list}
          routes: 16
      - name: listenerset
        config:
          gateways:
${gateway_list}
nodes:
- name: node
  count: 20
templates:
  tls-secret: |
    #refresh=true
    apiVersion: v1
    kind: Secret
    metadata:
      name: {{.Name}}
    type: kubernetes.io/tls
    stringData:
      tls.crt: |
    {{- if .Rand }}
${CERT_A}
    {{- else }}
${CERT_B}
    {{- end }}
      tls.key: |
    {{- if .Rand }}
${KEY_A}
    {{- else }}
${KEY_B}
    {{- end }}
  route: |
    #refresh=true
    {{ range \$rc := until (int .routes) }}
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
      name: {{\$.Name}}-{{.}}
    spec:
      hostnames:
        - {{\$.Name}}.example.com
      parentRefs:
      {{ range \$gw := \$.gateways }}
      {{ \$spl := split "/" \$gw }}
      - name: {{\$.Name}}-{{\$spl._1}}
        kind: ListenerSet
        group: gateway.networking.k8s.io
      {{ end }}
      rules:
        - backendRefs:
            - name: {{\$.Name}}
              port: 80
          matches:
            - path:
                type: PathPrefix
                value: /{{.}}/{{\$.RandNumber}}
    ---
    {{ end }}
  listenerset: |
    #refresh=false
    {{ range \$gw := .gateways }}
    {{ \$spl := split "/" \$gw }}
    apiVersion: gateway.networking.k8s.io/v1
    kind: ListenerSet
    metadata:
      name: {{\$.Name}}-{{\$spl._1}}
    spec:
      parentRef:
        name: {{\$spl._1}}
        namespace: {{\$spl._0}}
        kind: Gateway
        group: gateway.networking.k8s.io
      listeners:
        - name: {{\$.Name}}
          hostname: {{\$.Name}}.example.com
          protocol: HTTPS
          port: 443
          tls:
            mode: Terminate
            certificateRefs:
              - kind: Secret
                group: ""
                name: ns-cert
    ---
    {{ end }}
EOF
  run_end="$(date +%s)"
  # Capture the Prometheus data used by the ListenerSet scale graphs after the
  # long-running generator is stopped.
  if (( $# == 1 )); then
    export-prometheus-snapshot listenerset-load "$run_start" "$run_end" "$target"
  else
    export-prometheus-snapshot listenerset-load "$run_start" "$run_end"
  fi
}

# Default to loading one gateway at a time (see route-load.sh). Set COMBINED=1
# to attach every ListenerSet/route to all gateways in a single run.
if [[ "${COMBINED:-}" == "1" ]]; then
  run_load "${ls_gateways[@]}"
else
  for gw in "${ls_gateways[@]}"; do
    echo "listenerset-load: targeting ${gw}" >&2
    run_load "$gw"
  done
fi
wait_for_teardown
