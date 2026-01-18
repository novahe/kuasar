# kuasarctl Tests

This document describes the test suite for kuasarctl.

## Test Structure

```
kuasarctl/tests/
├── prefix_matching_test.rs    # Unit tests for pod ID resolution
├── integration_test.rs         # Integration tests for socket communication
├── command_execution_test.rs   # Integration tests for command execution
├── interactive_shell_test.rs   # Integration tests for interactive shell
└── README.md                   # This file
```

## Running Tests

### Run All Tests

```bash
cd /root/nova/kuasar/kuasar
cargo test -p kuasarctl
```

Expected output:
```
running 30 tests across 4 test files
test result: ok. 30 passed; 0 failed
```

### Run Specific Test Suites

```bash
# Run only prefix matching tests
cargo test -p kuasarctl --test prefix_matching_test

# Run only integration tests
cargo test -p kuasarctl --test integration_test

# Run only command execution tests
cargo test -p kuasarctl --test command_execution_test

# Run only interactive shell tests
cargo test -p kuasarctl --test interactive_shell_test
```

### Run a Specific Test

```bash
cargo test -p kuasarctl test_execute_simple_command
```

### Run with Output

```bash
cargo test -p kuasarctl -- --nocapture
```

## Test Coverage

### Unit Tests: Prefix Matching (12 tests)

These tests verify the pod ID prefix matching functionality:

| Test | Description |
|------|-------------|
| `test_list_available_pods_empty_directory` | Handles empty socket directory |
| `test_list_available_pods_with_valid_sockets` | Lists pods with valid sockets |
| `test_list_available_pods_ignores_dirs_without_socket` | Ignores directories without task.socket |
| `test_list_available_pods_sorted` | Verifies alphabetical sorting |
| `test_resolve_pod_id_exact_match` | Exact pod ID match |
| `test_resolve_pod_id_unique_prefix` | Unique prefix resolution |
| `test_resolve_pod_id_multiple_matches_error` | Multiple matches error |
| `test_resolve_pod_id_no_match_error` | No match error |
| `test_resolve_pod_id_empty_directory_error` | Empty directory error |
| `test_resolve_pod_id_single_character_prefix` | Single character prefix |
| `test_resolve_pod_id_numeric_prefix` | Numeric prefix handling |
| `test_resolve_pod_id_case_sensitive` | Case sensitivity |

### Integration Tests: Socket Communication (6 tests)

These tests verify the socket connection and communication protocol:

| Test | Description |
|------|-------------|
| `test_connect_protocol` | CONNECT command handshake |
| `test_connect_timeout_without_ok` | Timeout handling |
| `test_bidirectional_data_transfer` | Echo server functionality |
| `test_multiple_connections` | Concurrent connections |
| `test_connect_nonexistent_socket` | Non-existent socket error |
| `test_malformed_connect_command` | Malformed command handling |

### Command Execution Tests (7 tests)

These tests verify actual command execution and output handling:

| Test | Description |
|------|-------------|
| `test_execute_simple_command` | Execute a simple command (ls) and receive output |
| `test_execute_multiple_commands` | Execute multiple commands sequentially |
| `test_execute_command_with_long_output` | Handle commands with large output (ps aux) |
| `test_execute_command_with_error` | Handle command errors |
| `test_execute_command_with_pipeline` | Handle shell pipelines (|) |
| `test_command_timeout` | Handle command timeouts |
| `test_execute_command_with_structured_output` | Handle structured/JSON output |

### Interactive Shell Tests (5 tests)

These tests verify interactive shell behavior:

| Test | Description |
|------|-------------|
| `test_interactive_shell_prompt` | Shell prompt display |
| `test_interactive_session_multiple_commands` | Multiple commands in interactive session |
| `test_shell_tab_completion` | Tab completion simulation |
| `test_shell_history_navigation` | Command history (up/down arrows) |
| `test_shell_exit_command` | Shell exit behavior |

## Total Test Count

- **Unit Tests**: 12
- **Integration Tests**: 6
- **Command Execution Tests**: 7
- **Interactive Shell Tests**: 5
- **Total**: **30 tests**

## Writing New Tests

### Adding a Unit Test

```rust
#[test]
fn test_my_new_feature() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    // Create test data
    let pod_path = temp_dir.path().join("test-pod");
    fs::create_dir(&pod_path).expect("Failed to create pod dir");
    let socket_path = pod_path.join("task.socket");
    UnixListener::bind(&socket_path).expect("Failed to create socket");

    // Test the feature
    let result = resolve_pod_id(temp_dir.path().to_str().unwrap(), "test");

    // Assert expectations
    assert!(result.is_ok());
    assert_eq!(result.unwrap(), "test-pod");
}
```

### Adding a Command Execution Test

```rust
#[test]
fn test_my_command_execution() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    // Start mock server
    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            // Handle CONNECT
            let mut buf = [0; 4096];
            if let Ok(n) = stream.read(&mut buf) {
                if String::from_utf8_lossy(&buf[..n]).contains("CONNECT") {
                    let _ = stream.write_all(b"OK\n");
                    let _ = stream.flush();
                }
            }

            // Read command and send response
            let _ = stream.read(&mut buf);
            let _ = stream.write_all(b"command output\n");
        }
    });

    thread::sleep(Duration::from_millis(100));

    // Client: Execute command
    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    // ... test code ...
}
```

## Test Dependencies

Tests use the following dependencies:
- `tempfile`: For creating temporary directories and sockets
- `std::os::unix::net::{UnixListener, UnixStream}`: For Unix socket testing
- `thread`: For concurrent test scenarios
- `std::time::{Duration, Instant}`: For timing and timeouts

## CI/CD Integration

To run tests in CI:

```yaml
- name: Run kuasarctl tests
  run: |
    cd kuasar
    cargo test -p kuasarctl --verbose
```

## Test Debugging

### Enable Logging

```bash
RUST_LOG=debug cargo test -p kuasarctl -- --nocapture
```

### Run Single Test with Backtrace

```bash
RUST_BACKTRACE=1 cargo test -p kuasarctl test_execute_simple_command
```

### Run Tests with Detailed Output

```bash
cargo test -p kuasarctl -- --show-output
```

## Known Issues

1. **Timing-dependent tests**: Some tests use `thread::sleep` for synchronization. On slow systems, these may need adjustment.

2. **Platform-specific**: Tests use Unix sockets, so they only run on Unix-like systems (Linux, macOS, etc.).

3. **Concurrent test execution**: Tests use temporary directories to avoid conflicts, but running in highly parallel environments may have issues.

## Future Improvements

- [ ] Add property-based testing for prefix matching
- [ ] Add fuzzing for socket protocol parsing
- [ ] Add benchmarks for performance testing
- [ ] Add end-to-end tests with actual CLH VMs
- [ ] Add tests for exit code handling
- [ ] Add tests for signal handling (Ctrl+C, etc.)
