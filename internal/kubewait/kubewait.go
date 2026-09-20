// Package kubewait shells out to kubectl (available in the bench-runner pod) to
// wait for backend workloads to settle before a test starts probing.
package kubewait

import (
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// Rollout waits for the Deployment to roll out and then for every pod matching
// selector that is still terminating to disappear. A rollout leaves the old pod
// in Terminating for its grace period; some gateways keep routing to such
// "serving but terminating" endpoints, which would show up as errors that have
// nothing to do with the behaviour under test.
func Rollout(namespace, deployment, selector string, timeout time.Duration) error {
	out, err := exec.Command("kubectl", "rollout", "status", "deployment/"+deployment, "--namespace="+namespace, "--timeout="+timeout.String()).CombinedOutput()
	if err != nil {
		return fmt.Errorf("rollout %s: %v: %s", deployment, err, strings.TrimSpace(string(out)))
	}
	return NoTerminatingPods(namespace, selector, timeout)
}

// NoTerminatingPods blocks until no pod matching selector has a deletionTimestamp.
func NoTerminatingPods(namespace, selector string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		out, err := exec.Command("kubectl", "get", "pods", "--namespace="+namespace, "-l", selector,
			"-o", "jsonpath={range .items[*]}{.metadata.deletionTimestamp}{end}").Output()
		if err == nil && strings.TrimSpace(string(out)) == "" {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("pods matching %q still terminating after %s", selector, timeout)
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// DeleteDocs deletes every document of a multi-document YAML manifest using
// the supplied single-object delete function (pilot-load's DeleteRaw only
// handles one object per call).
func DeleteDocs(manifest string, deleteOne func(doc string) error) error {
	var firstErr error
	for _, doc := range strings.Split(manifest, "\n---") {
		if strings.TrimSpace(doc) == "" {
			continue
		}
		if err := deleteOne(doc); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
