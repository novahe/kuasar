package main

import (
	"testing"
	"time"
)

func TestParseLogLineTable(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name      string
		line      string
		wantOp    string
		wantDur   time.Duration
		wantValid bool
	}{
		{
			name:      "matches took log with sandbox id",
			line:      "2026-04-15T01:02:03.123Z info nova: sandboxer create sandbox 3d5d0e54-7b25-4e9d-9d56-123456789abc took 12.5ms",
			wantOp:    "sandboxer create sandbox",
			wantDur:   12500 * time.Microsecond,
			wantValid: true,
		},
		{
			name:      "matches took log (formerly in)",
			line:      "2026-04-15T09:02:03.123+08:00 info nova: agent check successful took 88ms",
			wantOp:    "agent check successful",
			wantDur:   88 * time.Millisecond,
			wantValid: true,
		},
		{
			name:      "ignores unrelated line",
			line:      "plain text without nova metrics",
			wantValid: false,
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got, ok := parseLogLine(tc.line)
			if ok != tc.wantValid {
				t.Fatalf("valid = %v, want %v", ok, tc.wantValid)
			}
			if !tc.wantValid {
				return
			}
			if got.Operation != tc.wantOp {
				t.Fatalf("operation = %q, want %q", got.Operation, tc.wantOp)
			}
			if got.Latency != tc.wantDur {
				t.Fatalf("latency = %v, want %v", got.Latency, tc.wantDur)
			}
		})
	}
}

func TestInsertStoresLatencyOnLeafOnly(t *testing.T) {
	t.Parallel()

	root := NewNode("root")
	ts := time.Date(2026, 4, 15, 1, 2, 3, 0, time.UTC)
	root.Insert([]string{"start sandbox", "start", "agent check"}, 25*time.Millisecond, ts)

	startNode := root.Children["start sandbox"].Children["start"]
	leafNode := startNode.Children["agent check"]

	if len(startNode.Latencies) != 0 {
		t.Fatalf("start node latencies = %d, want 0", len(startNode.Latencies))
	}
	if len(leafNode.Latencies) != 1 {
		t.Fatalf("leaf node latencies = %d, want 1", len(leafNode.Latencies))
	}
	if startNode.FirstTime.IsZero() || startNode.LastTime.IsZero() {
		t.Fatalf("start node window was not updated")
	}
}
