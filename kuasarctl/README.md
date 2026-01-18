# kuasarctl

A command-line tool for debugging and executing commands in Cloud Hypervisor (CLH) environments managed by Kuasar.

## Overview

`kuasarctl` provides convenient access to the debug console of Cloud Hypervisor VMs, enabling both interactive and non-interactive command execution.

## Features

- **Interactive mode** (`-it`): Access an interactive shell inside the CLH VM
- **Non-interactive mode** (`-t`): Execute commands and get output for scripting
- **Flexible socket path**: Customizable socket directory for different setups
- **Configurable port**: Support for different debug console ports
- **Prefix matching**: Use short pod ID prefixes instead of full IDs (e.g., `pod-abc` instead of `pod-abc-123`)

## Installation

### Build from source

```bash
cd /root/nova/kuasar/kuasar
cargo build --release -p kuasarctl
```

The binary will be available at `target/release/kuasarctl`.

### Install system-wide

```bash
cd /root/nova/kuasar/kuasar
make install-kuasarctl
```

## Usage

### Interactive Mode

For interactive shell access (similar to `kubectl exec -it`):

```bash
kuasarctl exec -it <pod_id>
```

Example:

```bash
# Start an interactive shell in the CLH VM
kuasarctl exec -it my-pod-12345

# Or specify a different shell
kuasarctl exec -it my-pod-12345 bash
```

### Non-Interactive Mode

For executing commands in scripts (similar to `kubectl exec` without `-i`):

```bash
kuasarctl exec -t <pod_id> <command>
```

Examples:

```bash
# List files in the VM
kuasarctl exec -t my-pod-12345 ls

# Check processes
kuasarctl exec -t my-pod-12345 ps aux

# Get environment variables
kuasarctl exec -t my-pod-12345 env

# Run multiple commands
kuasarctl exec -t my-pod-12345 "ls -la && ps aux"
```

### Advanced Options

```bash
# Use a different debug console port
kuasarctl exec -it -p 1026 my-pod-12345

# Specify custom socket directory
kuasarctl exec -it -d /var/run/kuasar my-pod-12345

# Combine options
kuasarctl exec -t -p 1025 -d /custom/path my-pod-12345 ls
```

### Prefix Matching (Short Names)

`kuasarctl` supports prefix matching for pod IDs, so you don't need to type the full ID:

```bash
# If full pod ID is "pod-abc-123", you can use:
kuasarctl exec -it pod-abc

# If prefix is unique, it will be resolved automatically
kuasarctl exec -t pod-xyz ls

# If prefix matches multiple pods, you'll see an error:
kuasarctl exec -it pod-abc
# Error: Pod prefix "pod-abc" matches multiple pods:
#   pod-abc-123
#   pod-abc-456
# Please provide a more specific prefix.
```

**Rules:**
1. Exact match takes priority (if you type the full pod ID, it's used directly)
2. If prefix matches exactly one pod, it's used automatically
3. If prefix matches multiple pods, an error is shown with all matches
4. If prefix matches nothing, an error shows all available pods

## Testing

`kuasarctl` includes comprehensive unit and integration tests:

### Run All Tests

```bash
cd /root/nova/kuasar/kuasar
cargo test -p kuasarctl
```

### Run Specific Test Suites

```bash
# Run only prefix matching tests
cargo test -p kuasarctl --test prefix_matching_test

# Run only integration tests
cargo test -p kuasarctl --test integration_test

# Run a specific test
cargo test -p kuasarctl test_resolve_pod_id_unique_prefix
```

### Test Coverage

The test suite includes:

**Unit Tests (12 tests):**
- Empty directory handling
- Valid socket listing
- Sorted pod listing
- Exact pod ID matching
- Unique prefix matching
- Multiple matches error handling
- No match error handling
- Single character prefix
- Numeric prefix
- Case sensitivity

**Integration Tests (6 tests):**
- CONNECT protocol handshake
- Timeout handling
- Bidirectional data transfer
- Multiple concurrent connections
- Non-existent socket error
- Malformed command handling

## How It Works

1. **Locates the socket**: Finds the `task.socket` file at `/run/kuasar/<pod_id>/`
2. **Establishes connection**: Connects via Unix socket and sends `CONNECT <port>` command
3. **Debug console**: Accesses the debug console running on vsock port 1025 (default)
4. **Data transfer**: Bidirectional data transfer between local terminal and VM shell

This mechanism is similar to the traditional method:

```bash
nc -U /run/kuasar/<pod_id>/task.socket
CONNECT 1025
# ... interact with shell ...
```

But `kuasarctl` provides a more user-friendly interface with proper terminal handling.

## Architecture

```
┌─────────────┐     Unix Socket      ┌──────────────┐     vsock     ┌──────────┐
│  kuasarctl  │◄────────────────────►│ task.socket  │◄────────────►│ CLH VM   │
│             │  CONNECT 1025        │              │   Port 1025  │ Debug    │
└─────────────┘                      └──────────────┘              └──────────┘
```

## Requirements

- Unix-like operating system (Linux)
- Rust 1.70+ (for building from source)
- Running CLH VM with debug console enabled
- Access to `/run/kuasar/<pod_id>/task.socket`

## Troubleshooting

### Socket file not found

```
Error: Socket file not found: /run/kuasar/<pod_id>/task.socket
```

**Solution**: Check if the pod/container is running:

```bash
ls -la /run/kuasar/
```

### Connection refused

```
Error: Failed to connect to socket
```

**Solution**: Verify the CLH VM is running and the debug console is enabled.

### Permission denied

**Solution**: Ensure you have the necessary permissions to access the socket file:

```bash
# Run with sudo if needed
sudo kuasarctl exec -it <pod_id>
```

## Comparison with kata-runtime exec

| Feature | kuasarctl | kata-runtime exec |
|---------|-----------|-------------------|
| Architecture | Rust | Go |
| Connection method | Unix socket + CONNECT | HTTP + vsock/hvsock |
| Dependencies | Minimal | Kata Containers runtime |
| Standalone | Yes | No (requires kata runtime) |
| Terminal handling | Native | Using containerd/console |

## Contributing

Contributions are welcome! Please submit pull requests to the Kuasar project.

## License

Apache License 2.0
