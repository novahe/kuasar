#!/bin/bash
# Example: Non-interactive command execution in CLH VM
# This demonstrates how to use kuasarctl for scripting

POD_ID="${1:-test-pod-12345}"

echo "Executing commands in CLH VM..."
echo "Pod ID: $POD_ID"
echo ""

# Example 1: List files
echo "=== Listing files in VM ==="
kuasarctl exec -t "$POD_ID" ls -la
echo ""

# Example 2: Check processes
echo "=== Checking running processes ==="
kuasarctl exec -t "$POD_ID" ps aux
echo ""

# Example 3: Get network information
echo "=== Network interfaces ==="
kuasarctl exec -t "$POD_ID" ip addr
echo ""

# Example 4: Check disk usage
echo "=== Disk usage ==="
kuasarctl exec -t "$POD_ID" df -h
echo ""
