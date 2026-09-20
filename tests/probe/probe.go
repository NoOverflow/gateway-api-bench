package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/howardjohn/gateway-api-bench/internal/csvwriter"
	"github.com/howardjohn/gateway-api-bench/internal/gwaddr"
	"github.com/howardjohn/gateway-api-bench/internal/kubewait"
	"github.com/howardjohn/pilot-load/pkg/flag"
	"github.com/howardjohn/pilot-load/pkg/kube"
	"github.com/howardjohn/pilot-load/pkg/simulation/model"
	"github.com/howardjohn/pilot-load/pkg/victoria"
	"github.com/spf13/pflag"
	"golang.org/x/sync/errgroup"
	"k8s.io/apimachinery/pkg/types"
	gateway "sigs.k8s.io/gateway-api/apis/v1beta1"

	"istio.io/istio/pkg/kube/kclient"
	"istio.io/istio/pkg/log"
	"istio.io/istio/pkg/sleep"
	"istio.io/istio/pkg/test/util/tmpl"
)

type Config struct {
	Gateways     []string
	GracePeriod  time.Duration
	VictoriaLogs string
	Routes       int
	InitialRoute int
	Output       string
}

func main() {
	flag.RunMain(Command)
}

func Command(f *pflag.FlagSet) flag.Command {
	cfg := Config{
		Routes: 10,
	}

	flag.Register(f, &cfg.Gateways, "gateways", "list of gateways to use").Required()
	flag.Register(f, &cfg.Routes, "routes", "number of routes")
	flag.Register(f, &cfg.InitialRoute, "initial-route", "which route to start tests on")
	flag.Register(f, &cfg.Output, "output", "CSV file for static samples")
	flag.Register(f, &cfg.VictoriaLogs, "victoria", "victoria-logs address")
	flag.Register(f, &cfg.GracePeriod, "gracePeriod", "delay between each application")
	return flag.Command{
		Name:        "gatewayapi-probe",
		Description: "apply routes and measure time until traffic is accepted",
		Build: func(args *model.Args) (model.DebuggableSimulation, error) {
			st := map[types.NamespacedName]*Watcher{}
			for _, gw := range cfg.Gateways {
				t := parseNamespacedName(gw)
				st[t] = &Watcher{
					Name:    t,
					Client:  &http.Client{},
					Last:    0,
					Samples: nil,
				}
			}
			output, err := csvwriter.New(cfg.Output, []string{"timestamp_unix_nano", "gateway", "route", "latency_microseconds", "errors"})
			if err != nil {
				return nil, err
			}
			return &ProbeTest{Config: cfg, State: st, Output: output}, nil
		},
	}
}

func parseNamespacedName(gw string) types.NamespacedName {
	ns, name, _ := strings.Cut(gw, "/")
	return types.NamespacedName{Namespace: ns, Name: name}
}

type ProbeTest struct {
	Config Config
	State  map[types.NamespacedName]*Watcher
	Output *csvwriter.Writer
}

var _ model.Simulation = &ProbeTest{}

// Each test owns a distinctly named backend so a Service of one test never
// selects another test's pods (they all live in the default namespace).
const backendTemplate = `
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-probe
spec:
  selector:
    matchLabels:
      app: backend-probe
  template:
    metadata:
      labels:
        app: backend-probe
    spec:
      containers:
      - name: backend
        image: howardjohn/hyper-server
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: backend-probe
spec:
  selector:
    app: backend-probe
  ports:
  - name: http
    port: 80
    targetPort: 8080
`

const cfgTemplate = `
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{.Index}}-route
  namespace: {{.Namespace}}
spec:
  hostnames:
    - {{.Index}}-route.example.com
  parentRefs:
  {{ range $gw := .Gateways }}
  {{ $spl := split "/" $gw }}
  - name: {{$spl._1}}
    namespace: {{$spl._0}}
  {{ end }}
  rules:
    - backendRefs:
        - name: backend-probe
          port: 80
      filters:
      - type: RequestHeaderModifier
        requestHeaderModifier:
          add:
          - name: added-header
            value: added-value
      - type: ResponseHeaderModifier
        responseHeaderModifier:
          add:
          - name: added-resp-header
            value: added-resp-value
      matches:
        - path:
            type: PathPrefix
            value: /{{.Index}}
    - backendRefs:
        - name: invalid-backend
          port: 80
      filters:
      - type: RequestHeaderModifier
        requestHeaderModifier:
          add:
          - name: added-header
            value: added-value
      - type: ResponseHeaderModifier
        responseHeaderModifier:
          add:
          - name: added-resp-header
            value: added-resp-value
      matches:
        - path:
            type: PathPrefix
            value: /
`

func (a *ProbeTest) GetConfig() any {
	return a.Config
}

func (a *ProbeTest) Run(ctx model.Context) error {
	gtws := kclient.New[*gateway.Gateway](ctx.Client)
	// routes := kclient.New[*gateway.HTTPRoute](ctx.Client)
	ctx.Client.RunAndWait(ctx.Done())
	for _, gw := range a.State {
		g := gtws.Get(gw.Name.Name, gw.Name.Namespace)
		if g == nil {
			return fmt.Errorf("gateway %v not found", gw.Name)
		}
		status := ""
		if a := g.Status.Addresses; len(a) > 0 {
			status = a[0].Value
		}
		gw.Address = gwaddr.Resolve(gw.Name, status)
		if gw.Address == "" {
			return fmt.Errorf("gateway %v has no address", gw.Name)
		}
	}

	if err := kube.ApplyTemplate(ctx.Client, "default", backendTemplate, nil); err != nil {
		return err
	}
	if err := kubewait.Rollout("default", "backend-probe", "app=backend-probe", 2*time.Minute); err != nil {
		return fmt.Errorf("wait for backend readiness: %w", err)
	}
	for r := range a.Config.Routes {
		type cfg struct {
			Index     int
			Namespace string
			Gateways  []string
		}
		data := cfg{
			Index:     r,
			Namespace: "default",
			Gateways:  a.Config.Gateways,
		}
		if err := kube.ApplyTemplate(ctx.Client, "default", cfgTemplate, data); err != nil {
			return err
		}
		if r == a.Config.InitialRoute-1 {
			log.Infof("applied last route, waiting...")
			time.Sleep(time.Second * 10)
		}
		if r < a.Config.InitialRoute {
			log.Infof("skipping, initial route not yet hit")
			continue
		}
		g := errgroup.Group{}
		for _, gw := range a.State {
			hostname := fmt.Sprintf("%d-route.example.com", r)
			g.Go(func() error {
				if err := gw.Probe(ctx.Context, hostname, r, a.Output); err != nil {
					return fmt.Errorf("%v: %v", gw.Name, err)
				}
				return nil
			})
		}
		if err := g.Wait(); err != nil {
			return err
		}
		// Periodically report
		if (r+1)%50 == 0 {
			a.Report()
		}
	}

	ctx.Cancel()
	return nil
}

func (a *ProbeTest) Cleanup(ctx model.Context) error {
	defer a.Output.Close()
	a.Report()

	for r := range a.Config.Routes {
		type cfg struct {
			Index     int
			Namespace string
			Gateways  []string
		}
		spec := tmpl.MustEvaluate(cfgTemplate, cfg{
			Index:     r,
			Namespace: "default",
			Gateways:  a.Config.Gateways,
		})
		if err := kube.DeleteRaw(ctx.Client, "default", spec); err != nil {
			log.Errorf("failed to delete route %d: %v", r, err)
		}
	}
	if err := kubewait.DeleteDocs(backendTemplate, func(doc string) error { return kube.DeleteRaw(ctx.Client, "default", doc) }); err != nil {
		log.Errorf("failed to delete backend: %v", err)
	}
	return nil
}

func (a *ProbeTest) AllEqual(key types.NamespacedName, want int) error {
	processed := func(w *Watcher) error {
		if w.Samples == nil {
			return fmt.Errorf("%v not initialized", w.Name)
		}
		if w.Last != want {
			return fmt.Errorf("want %d, got %d for %v", want, w.Last, w.Name)
		}
		return nil
	}
	// Check the one we are currently processing to avoid confusing logs
	if err := processed(a.State[key]); err != nil {
		return err
	}
	for _, w := range a.State {
		if err := processed(w); err != nil {
			return err
		}
	}
	return nil
}

func (a *ProbeTest) Report() {
	for _, gw := range a.State {
		totalErrors := 0
		totalLatency := time.Duration(0)
		maxLatency := time.Duration(0)
		for _, sample := range gw.Samples {
			totalErrors += sample.Errors
			totalLatency += sample.Latency
			maxLatency = max(maxLatency, sample.Latency)
		}
		// TODO: average latency, total latency, max
		log.WithLabels("gateway", gw.Name, "errors", totalErrors, "runtime", totalLatency, "max", maxLatency).Info("test complete")
	}

	if a.Config.VictoriaLogs != "" {
		var entries []VicLogEntry
		for name, w := range a.State {
			for _, sample := range w.Samples {
				entries = append(entries, VicLogEntry{
					Message: "event",
					Test:    "probe",
					Gateway: name.String(),
					Time:    sample.Time.UnixNano(),
					Value:   sample.Latency.Microseconds(),
				})
			}
		}
		if err := victoria.Report(a.Config.VictoriaLogs, []string{"gateway", "test"}, entries); err != nil {
			log.Errorf("failed to report victoria logs: %v", err)
		} else {
			log.Infof("reported victoria logs")
		}
	}
}

type VicLogEntry struct {
	Message string `json:"_msg"`
	Gateway string `json:"gateway"`
	Test    string `json:"test"`
	Time    int64  `json:"_time"`
	Value   int64  `json:"value"` // Microseconds
}

type Watcher struct {
	Name    types.NamespacedName
	Client  *http.Client
	Address string
	Last    int
	Samples []Sample
}

func (w *Watcher) Probe(ctx context.Context, hostname string, r int, output *csvwriter.Writer) error {
	log := log.WithLabels("gateway", w.Name.String(), "iter", r)
	t0 := time.Now()
	delay := time.Millisecond * 5
	errors := 0
	for range 1000000 {
		url := fmt.Sprintf("http://%s/%d", w.Address, r)
		req, err := http.NewRequest("GET", url, nil)
		if err != nil {
			return err
		}
		req.Host = hostname
		resp, err := w.Client.Do(req)
		if err != nil {
			return err
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		c := resp.StatusCode
		log.Debugf("probe result: %v", c)
		switch c {
		case 404:
			sleep.UntilContext(ctx, delay)
			continue
		case 200:
			tn := time.Now()
			w.Samples = append(w.Samples, Sample{
				Time:    time.Now(),
				Latency: tn.Sub(t0),
				Iter:    r,
				Errors:  errors,
			})
			if err := output.Write([]string{strconv.FormatInt(tn.UnixNano(), 10), w.Name.String(), strconv.Itoa(r), strconv.FormatInt(tn.Sub(t0).Microseconds(), 10), strconv.Itoa(errors)}); err != nil {
				return fmt.Errorf("write static sample: %w", err)
			}
			// success!
			// Todo continue a few to ensure we get 200 consistently
			log.WithLabels("latency", tn.Sub(t0)).Infof("probe completed: %v", c)
			return nil
		default:
			log.Errorf("unexpected status code: %v", c)
			sleep.UntilContext(ctx, delay)
			errors++
			continue
		}
	}
	return fmt.Errorf("timed out waiting for %v", w)
}

type Sample struct {
	Iter    int
	Time    time.Time
	Latency time.Duration
	Errors  int
}
