# kuasarctl Examples

This directory contains example scripts demonstrating various use cases for `kuasarctl`.

**Note:** All examples support prefix matching for pod IDs. Instead of using full pod IDs like `pod-abc-123`, you can use unique prefixes like `pod-abc`.

## Available Examples

### 1. Interactive Shell (`interactive-shell.sh`)

Demonstrates interactive shell access to a CLH VM.

```bash
./interactive-shell.sh <pod_id>
```

**Use case**: Manual debugging and interactive troubleshooting.

### 2. Non-Interactive Execution (`non-interactive-exec.sh`)

Shows how to execute multiple commands and get their output.

```bash
./non-interactive-exec.sh <pod_id>
```

**Use case**: Gathering information from the VM in a script.

### 3. Health Check (`health-check.sh`)

Performs automated health checks on a CLH VM.

```bash
./health-check.sh <pod_id> [verbose]
```

**Use case**: Monitoring and alerting.

**Exit codes**:
- `0`: All checks passed
- `1`: One or more checks failed

**Example with verbose output**:
```bash
./health-check.sh my-pod-12345 true
```

### 4. Batch Operations (`batch-operations.sh`)

Executes a command on multiple pods.

```bash
./batch-operations.sh "<command>"
```

**Use case**: Managing multiple VMs simultaneously.

**Example**: Check uptime on all pods
```bash
./batch-operations.sh uptime
```

**Example**: Check disk usage
```bash
./batch-operations.sh "df -h"
```

## Common Usage Patterns

### Checking Pod Status

```bash
# Check if a pod is running
if [ -S "/run/kuasar/<pod_id>/task.socket" ]; then
    echo "Pod is running"
    kuasarctl exec -t <pod_id> ps aux
else
    echo "Pod is not running"
fi
```

### Capturing Output to File

```bash
# Capture command output to a file
kuasarctl exec -t <pod_id> "ps aux" > output.txt
```

### Conditional Execution

```bash
# Execute command only if pod is running
if kuasarctl exec -t <pod_id> true 2>/dev/null; then
    echo "Pod is accessible"
    kuasarctl exec -t <pod_id> <your_command>
fi
```

### Loop Over Multiple Pods

```bash
# Execute command on all running pods
for socket in /run/kuasar/*/task.socket; do
    pod_id=$(basename $(dirname "$socket"))
    echo "Processing $pod_id..."
    kuasarctl exec -t "$pod_id" <your_command>
done
```

### Error Handling

```bash
# Handle errors gracefully
if ! output=$(kuasarctl exec -t <pod_id> <command> 2>&1); then
    echo "Error executing command: $output"
    exit 1
fi
echo "Command output: $output"
```

## Integration with Monitoring Tools

### Prometheus-compatible Metrics

```bash
#!/bin/bash
pod_id="$1"
metric_name="clh_vm_uptime_seconds"

uptime=$(kuasarctl exec -t "$pod_id" "cat /proc/uptime" | cut -d' ' -f1)
echo "# HELP $metric_name VM uptime in seconds"
echo "# TYPE $metric_name gauge"
echo "${metric_name}{pod_id=\"${pod_id}\"} ${uptime}"
```

### Alert Manager Integration

```bash
#!/bin/bash
pod_id="$1"

# Check for high CPU usage
cpu_usage=$(kuasarctl exec -t "$pod_id" "top -bn1 | grep 'Cpu(s)' | awk '{print \$2}' | cut -d'%' -f1")

if (( $(echo "$cpu_usage > 80" | bc -l) )); then
    echo "ALERT: High CPU usage on $pod_id: ${cpu_usage}%"
    # Send to alert manager
fi
```

## Tips and Best Practices

1. **Always check socket existence** before running commands to avoid errors
2. **Use non-interactive mode (`-t`)** for scripts to avoid TTY allocation issues
3. **Set timeouts** for commands that might hang
4. **Parse output carefully** - VM output format may vary
5. **Handle errors** gracefully in scripts
6. **Use verbose mode** (`RUST_LOG=debug`) for debugging connection issues

## Troubleshooting

### Enable Debug Logging

```bash
RUST_LOG=debug kuasarctl exec -it <pod_id>
```

### Check Socket Permissions

```bash
ls -la /run/kuasar/<pod_id>/task.socket
```

### Test Connection Manually

```bash
# Manual connection test
echo "CONNECT 1025" | nc -U /run/kuasar/<pod_id>/task.socket
```

## See Also

- [Main README](../README.md) - General kuasarctl documentation
- [Kuasar Project Documentation](../../docs/) - Overall Kuasar architecture
