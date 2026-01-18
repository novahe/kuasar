#!/bin/bash
# Example: Interactive shell access to CLH VM
# This demonstrates how to use kuasarctl for interactive debugging

POD_ID="${1:-test-pod-12345}"

echo "Starting interactive shell in CLH VM..."
echo "Pod ID: $POD_ID"
echo ""

# Start interactive shell with PTY
kuasarctl exec -it "$POD_ID"
