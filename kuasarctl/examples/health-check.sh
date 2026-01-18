#!/bin/bash
# Example: Health check script for CLH VM
# This demonstrates how to use kuasarctl for automated monitoring

POD_ID="${1:-test-pod-12345}"
VERBOSE="${2:-false}"

# Function to execute command and check output
check_command() {
    local pod_id="$1"
    local command="$2"
    local expected_pattern="$3"
    local description="$4"

    echo "Checking: $description"
    output=$(kuasarctl exec -t "$pod_id" "$command" 2>&1)

    if echo "$output" | grep -q "$expected_pattern"; then
        echo "  ✓ PASS"
        [ "$VERBOSE" = "true" ] && echo "  Output: $output"
        return 0
    else
        echo "  ✗ FAIL"
        [ "$VERBOSE" = "true" ] && echo "  Output: $output"
        return 1
    fi
}

echo "CLH VM Health Check"
echo "Pod ID: $POD_ID"
echo "===================="
echo ""

# Check if socket exists
if [ ! -S "/run/kuasar/$POD_ID/task.socket" ]; then
    echo "✗ Socket file not found: /run/kuasar/$POD_ID/task.socket"
    echo "  Please check if the pod/container is running."
    exit 1
fi

# Perform health checks
FAILED=0

check_command "$POD_ID" "cat /proc/1/comm" "init" "Init process" || FAILED=$((FAILED + 1))
check_command "$POD_ID" "mount | grep /proc" "proc" "Proc filesystem" || FAILED=$((FAILED + 1))
check_command "$POD_ID" "ip link show" "lo" "Loopback interface" || FAILED=$((FAILED + 1))
check_command "$POD_ID" "ls /dev" "null" "Device files" || FAILED=$((FAILED + 1))

echo ""
if [ $FAILED -eq 0 ]; then
    echo "Health check: PASSED"
    exit 0
else
    echo "Health check: FAILED ($FAILED check(s) failed)"
    exit 1
fi
