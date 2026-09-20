// Package gwaddr resolves the network address the load tests should dial for a
// given Gateway.
//
// By default the tests use the Gateway's first status address (a LoadBalancer
// IP on a typical cloud cluster). On setups where that address is not reachable
// from where the test runs -- e.g. CRC/OpenShift Local, where the tests run
// inside the cluster and dial the gateways by their in-cluster Service DNS --
// set the GATEWAY_ADDRESS_OVERRIDES env var to a comma-separated list of
// "namespace/name=host:port" entries to override the dialled address per
// gateway. common.sh builds this automatically from the known gateway Services.
package gwaddr

import (
	"os"
	"strings"

	"k8s.io/apimachinery/pkg/types"
)

const OverridesEnv = "GATEWAY_ADDRESS_OVERRIDES"

// Resolve returns the address to dial for the given gateway. If an override for
// the gateway is present in GATEWAY_ADDRESS_OVERRIDES it wins; otherwise
// fallback (typically the gateway's status address) is returned.
func Resolve(name types.NamespacedName, fallback string) string {
	env := os.Getenv(OverridesEnv)
	if env == "" {
		return fallback
	}
	key := name.Namespace + "/" + name.Name
	for _, pair := range strings.Split(env, ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(pair), "=")
		if ok && strings.TrimSpace(k) == key {
			return strings.TrimSpace(v)
		}
	}
	return fallback
}
