package main

import (
	"bufio"
	"fmt"
	"math"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"
)

// --- Configuration ---

const NameWidth = 60 // Width for tree names before vertical stats alignment

var (
	sbPath    = []string{"containerd run sandbox", "start sandbox"}
	sbCreate  = path(sbPath, "create")
	sbStart   = path(sbPath, "start")
	sbStart2  = path(sbStart, "start")
	sbGuest   = path(sbPath, "guest_init")
	sbShared  = path(sbGuest, "shared_init")
	ctrPath   = []string{"containerd create container"}
	quarkSb   = []string{"start Quark Sandbox"}
	quarkCtr  = []string{"start container"}
)

func path(prefix []string, segments ...string) []string {
	return append(append([]string(nil), prefix...), segments...)
}

// MountTable defines how log operation keys map to the tree hierarchy.
// Key: The string found between "nova:" and "took" in the logs.
// Value: The slice of strings representing the path in the tree.
var MountTable = map[string][]string{
	// Containerd CRI Wrapping
	"containerd run sandbox":      {"containerd run sandbox"},
	"containerd create container": {"containerd create container"},

	// VMM Sandboxer (Host)
	"start sandbox":             sbPath,
	"sandboxer create sandbox":  sbCreate,
	"sandboxer create_vm":       path(sbCreate, "sandboxer create_vm"),
	"sandbox setup files":       path(sbCreate, "setup_sandbox_files"),
	"sandbox prepare network":   path(sbStart, "prepare_network"),
	"sandboxer start sandbox":   sbStart,
	"sandbox start":             sbStart2,
	"cloud hypervisor start":    path(sbStart2, "cloud hypervisor start"),
	"sandboxer connect to task": path(sbStart2, "sandboxer connect to task"),
	"agent check successful":    path(sbStart2, "agent check"),
	"sandbox setup rpc":         path(sbStart2, "sandbox setup rpc"),
	"task setup sandbox":        path(sbStart2, "sandbox setup rpc", "task setup sandbox"),
	"sandbox add to cgroup":     path(sbStart, "add_to_cgroup"),

	// VMM Task (Guest)
	"task server pre-initialization complete": path(sbGuest, "pre_initialization"),
	"task init_vm_rootfs mount core fs":       path(sbGuest, "rootfs", "mount core fs"),
	"task init_vm_rootfs write sysctls":       path(sbGuest, "rootfs", "write sysctls"),
	"task ttrpc server started":               path(sbGuest, "ttrpc_start"),
	"task shared_init mount 9p sharefs":       path(sbShared, "mount sharefs"),
	"task shared_init mount virtiofs sharefs": path(sbShared, "mount sharefs"),
	"task shared_init late_init_call":         path(sbShared, "late_init"),
	"task rpc wait_for_ready":                 path(sbStart2, "rpc gating wait"),

	// Container Lifecycle
	"task create container": path(ctrPath, "create container"),
	"task start container":  path(ctrPath, "start container"),
	"task start exec":       path(ctrPath, "start exec"),

	// Quark specific (Example expansion)
	"load_quark_kernel":     path(quarkSb, "create", "load_kernel"),
	"enter_enclave":         path(quarkSb, "start", "enter_enclave"),
	"quark_container_start": path(quarkCtr, "start", "quark_start"),
}

// --- Data Structures ---

type Node struct {
	Name      string
	Children  map[string]*Node
	ChildKeys []string // Maintains order
	Latencies []time.Duration
	FirstTime time.Time
	LastTime  time.Time
}

type Stats struct {
	Count int
	Avg   float64
	P90   float64
	P95   float64
	Max   float64
}

func NewNode(name string) *Node {
	return &Node{
		Name:     name,
		Children: make(map[string]*Node),
	}
}

// --- Sorting ---

type DurationSlice []time.Duration

func (s DurationSlice) Len() int           { return len(s) }
func (s DurationSlice) Less(i, j int) bool { return s[i] < s[j] }
func (s DurationSlice) Swap(i, j int)      { s[i], s[j] = s[j], s[i] }

// --- Analysis Logic ---

func (n *Node) Insert(path []string, latency time.Duration, ts time.Time) {
	curr := n
	for i, step := range path {
		if _, ok := curr.Children[step]; !ok {
			curr.Children[step] = NewNode(step)
			curr.ChildKeys = append(curr.ChildKeys, step)
		}
		curr = curr.Children[step]
		// Aggregate time window for parent nodes as well
		if curr.FirstTime.IsZero() || ts.Before(curr.FirstTime) {
			curr.FirstTime = ts
		}
		if ts.After(curr.LastTime) {
			curr.LastTime = ts
		}
		// Only the leaf node keeps direct latency samples.
		// Parent nodes remain grouping nodes, and their Window reflects the subtree span.
		if i == len(path)-1 {
			curr.Latencies = append(curr.Latencies, latency)
		}
	}
}

func (n *Node) CalculateStats() *Stats {
	if len(n.Latencies) == 0 {
		return nil
	}
	sorted := make(DurationSlice, len(n.Latencies))
	copy(sorted, n.Latencies)
	sort.Sort(sorted)

	var total float64
	for _, d := range sorted {
		total += float64(d.Nanoseconds()) / 1e6
	}

	p90Idx := int(math.Ceil(float64(len(sorted))*0.9)) - 1
	p95Idx := int(math.Ceil(float64(len(sorted))*0.95)) - 1
	if p90Idx < 0 {
		p90Idx = 0
	}
	if p95Idx < 0 {
		p95Idx = 0
	}

	return &Stats{
		Count: len(sorted),
		Avg:   total / float64(len(sorted)),
		P90:   float64(sorted[p90Idx].Nanoseconds()) / 1e6,
		P95:   float64(sorted[p95Idx].Nanoseconds()) / 1e6,
		Max:   float64(sorted[len(sorted)-1].Nanoseconds()) / 1e6,
	}
}

// --- Rendering ---

func (n *Node) Render(level int, isLast bool, prefix string) {
	if level > 0 {
		connector := "├── "
		if isLast {
			connector = "└── "
		}

		displayName := prefix + connector + n.Name
		padding := ""
		displayLen := displayWidth(displayName)
		if displayLen < NameWidth {
			padding = strings.Repeat(" ", NameWidth-displayLen)
		}

		fmt.Print(displayName)
		fmt.Print(padding)

		stats := n.CalculateStats()
		if stats != nil {
			fmt.Printf(" (count: %3d, p90: %7.2fms, p95: %7.2fms, avg: %7.2fms, max: %7.2fms)",
				stats.Count, stats.P90, stats.P95, stats.Avg, stats.Max)
		}

		if !n.FirstTime.IsZero() && !n.LastTime.IsZero() {
			window := n.LastTime.Sub(n.FirstTime)
			fmt.Printf(" [Window: %v]", window.Round(time.Millisecond))
		}
		fmt.Println()
	}

	newPrefix := prefix
	if level > 0 {
		if isLast {
			newPrefix += "    "
		} else {
			newPrefix += "│   "
		}
	}

	for i, key := range n.ChildKeys {
		n.Children[key].Render(level+1, i == len(n.ChildKeys)-1, newPrefix)
	}
}

// --- Main ---

// Regex to match timestamp, operation, and duration.
var logRegex = regexp.MustCompile(`(?i)(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})).*nova: (?P<op>.*?) (?:[a-f0-9\-]{8,}\s+)?(?:took|in) (?P<dur>[\d\.]+(?:ns|us|µs|μs|ms|s|m|h))`)

type ParsedLog struct {
	Timestamp time.Time
	Operation string
	Latency   time.Duration
}

func parseLogLine(line string) (ParsedLog, bool) {
	matches := logRegex.FindStringSubmatch(line)
	if len(matches) == 0 {
		return ParsedLog{}, false
	}

	tsStr := matches[logRegex.SubexpIndex("ts")]
	op := strings.TrimSpace(matches[logRegex.SubexpIndex("op")])
	durStr := matches[logRegex.SubexpIndex("dur")]

	durStr = strings.ReplaceAll(durStr, "µs", "us")
	durStr = strings.ReplaceAll(durStr, "μs", "us")
	latency, err := time.ParseDuration(durStr)
	if err != nil {
		return ParsedLog{}, false
	}

	ts, err := time.Parse(time.RFC3339Nano, tsStr)
	if err != nil {
		ts, err = time.Parse(time.RFC3339, tsStr)
		if err != nil {
			return ParsedLog{}, false
		}
	}

	return ParsedLog{
		Timestamp: ts,
		Operation: op,
		Latency:   latency,
	}, true
}

func displayWidth(s string) int {
	width := 0
	for _, r := range s {
		if isWideRune(r) {
			width += 2
			continue
		}
		width++
	}
	return width
}

func isWideRune(r rune) bool {
	return unicode.In(r, unicode.Han, unicode.Hangul, unicode.Hiragana, unicode.Katakana) ||
		(r >= 0x3000 && r <= 0x303F) ||
		(r >= 0xFF01 && r <= 0xFF60) ||
		(r >= 0xFFE0 && r <= 0xFFE6)
}

func main() {
	root := NewNode("Root")
	scanner := bufio.NewScanner(os.Stdin)

	for scanner.Scan() {
		line := scanner.Text()
		entry, ok := parseLogLine(line)
		if !ok {
			continue
		}

		// Map to tree
		if path, ok := MountTable[entry.Operation]; ok {
			root.Insert(path, entry.Latency, entry.Timestamp)
		}
	}

	fmt.Println("\nkuasar 日志分析结果 (单位: ms)")
	fmt.Println("统计格式: 叶子节点显示直接事件分布 (count, p90, p95, avg, max) | Window: 子树时间跨度")
	fmt.Println(strings.Repeat("=", 120))
	root.Render(0, true, "")
	fmt.Println(strings.Repeat("=", 120))
}
