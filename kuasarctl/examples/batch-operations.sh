#!/bin/bash
# Example: Batch operations on multiple CLH VMs
# This demonstrates how to manage multiple pods with kuasarctl

# List of pod IDs to operate on
PODS=(
    "pod-001"
    "pod-002"
    "pod-003"
)

COMMAND="${1:-uptime}"
TIMEOUT=5

echo "Executing '$COMMAND' on ${#PODS[@]} pod(s)..."
echo "========================================="
echo ""

for pod in "${PODS[@]}"; do
    echo "Pod: $pod"

    # Check if socket exists
    if [ ! -S "/run/kuasar/$pod/task.socket" ]; then
        echo "  Status: NOT RUNNING (socket not found)"
        echo ""
        continue
    fi

    # Execute command with timeout
    if timeout $TIMEOUT kuasarctl exec -t "$pod" "$COMMAND" 2>&1; then
        echo "  Status: SUCCESS"
    else
        exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "  Status: TIMEOUT"
        else
            echo "  Status: ERROR (exit code: $exit_code)"
        fi
    fi
    echo ""
done

echo "Batch operation completed."
