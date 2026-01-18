/*
Copyright 2025 The Kuasar Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

//! Integration tests for actual command execution and output handling

use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::thread;
use std::time::Duration;
use tempfile::TempDir;

/// Test executing a simple command and receiving output
#[test]
fn test_execute_simple_command() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    // Mock server that simulates CLH debug console
    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0; 4096];

            // Handle CONNECT protocol
            if let Ok(n) = stream.read(&mut buf) {
                let request = String::from_utf8_lossy(&buf[..n]);
                if request.contains("CONNECT 1025") {
                    let _ = stream.write_all(b"OK\n");
                }
            }

            // Read command
            let mut cmd_buf = Vec::new();
            let mut line_buf = [0; 1024];
            if let Ok(n) = stream.read(&mut line_buf) {
                let cmd = String::from_utf8_lossy(&line_buf[..n]);
                cmd_buf.extend_from_slice(&line_buf[..n]);

                // Simulate command execution
                if cmd.contains("ls") {
                    // Send fake ls output
                    let _ = stream.write_all(b"bin\nboot\ndev\netc\nhome\n");
                } else if cmd.contains("pwd") {
                    // Send fake pwd output
                    let _ = stream.write_all(b"/root\n");
                }
            }

            // Wait a bit then close connection
            thread::sleep(Duration::from_millis(100));
        }
    });

    thread::sleep(Duration::from_millis(100));

    // Client: Execute command
    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("Failed to set timeout");

    // Send CONNECT
    stream
        .write_all(b"CONNECT 1025\n")
        .expect("Failed to send CONNECT");

    // Wait for OK
    let mut buf = [0; 1024];
    let mut ok_received = false;
    for _ in 0..10 {
        if let Ok(n) = stream.read(&mut buf) {
            if String::from_utf8_lossy(&buf[..n]).contains("OK") {
                ok_received = true;
                break;
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
    assert!(ok_received);

    stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();

    // Send command
    stream.write_all(b"ls\n").expect("Failed to send command");

    // Read response
    let mut output = String::new();
    let start = std::time::Instant::now();
    while start.elapsed() < Duration::from_secs(1) {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                output.push_str(&String::from_utf8_lossy(&buf[..n]));
                if output.contains("home") {
                    break;
                }
            }
            Err(_) => break,
        }
    }

    assert!(output.contains("bin"));
    assert!(output.contains("etc"));
    assert!(output.contains("home"));
}

/// Test executing multiple commands sequentially
#[test]
fn test_execute_multiple_commands() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0; 4096];

            // Handle CONNECT
            if let Ok(n) = stream.read(&mut buf) {
                if String::from_utf8_lossy(&buf[..n]).contains("CONNECT") {
                    let _ = stream.write_all(b"OK\n");
                }
            }

            // Handle commands
            for expected_cmd in &["pwd", "whoami", "hostname"] {
                let mut cmd_buf = [0; 1024];
                if let Ok(n) = stream.read(&mut cmd_buf) {
                    let cmd = String::from_utf8_lossy(&cmd_buf[..n]);

                    if cmd.contains(*expected_cmd) {
                        match *expected_cmd {
                            "pwd" => {
                                let _ = stream.write_all(b"/root\n");
                            }
                            "whoami" => {
                                let _ = stream.write_all(b"root\n");
                            }
                            "hostname" => {
                                let _ = stream.write_all(b"test-vm\n");
                            }
                            _ => {}
                        }
                    }
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
    });

    thread::sleep(Duration::from_millis(100));

    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("Failed to set timeout");

    // CONNECT
    stream.write_all(b"CONNECT 1025\n").unwrap();
    let mut buf = [0; 1024];
    for _ in 0..10 {
        if let Ok(n) = stream.read(&mut buf) {
            if String::from_utf8_lossy(&buf[..n]).contains("OK") {
                break;
            }
        }
    }

    // Execute commands
    let commands = vec!["pwd", "whoami", "hostname"];
    let mut outputs = Vec::new();

    for cmd in commands {
        stream
            .write_all(format!("{}\n", cmd).as_bytes())
            .expect("Failed to send command");

        let mut output = String::new();
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_millis(500) {
            match stream.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    output.push_str(&String::from_utf8_lossy(&buf[..n]));
                    if !output.is_empty() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        outputs.push(output.trim().to_string());
        thread::sleep(Duration::from_millis(50));
    }

    assert_eq!(outputs[0], "/root");
    assert_eq!(outputs[1], "root");
    assert_eq!(outputs[2], "test-vm");
}

/// Test command with long output
#[test]
fn test_execute_command_with_long_output() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0; 4096];

            // Handle CONNECT
            if let Ok(n) = stream.read(&mut buf) {
                if String::from_utf8_lossy(&buf[..n]).contains("CONNECT") {
                    let _ = stream.write_all(b"OK\n");
                }
            }

            // Read command
            let _ = stream.read(&mut buf);

            // Generate long output (simulating ps aux or similar)
            // Write all at once for simplicity
            let mut output = String::new();
            for i in 1..=20 {
                output.push_str(&format!("process{:03}   user   {}   0.0   cpu-command\n", i, i * 100));
            }
            let _ = stream.write_all(output.as_bytes());
        }
    });

    thread::sleep(Duration::from_millis(100));

    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("Failed to set timeout");

    // CONNECT
    stream.write_all(b"CONNECT 1025\n").unwrap();
    let mut buf = [0; 8192];  // Larger buffer
    for _ in 0..10 {
        if let Ok(n) = stream.read(&mut buf) {
            if String::from_utf8_lossy(&buf[..n]).contains("OK") {
                break;
            }
        }
    }

    stream.set_read_timeout(None).unwrap();

    // Send command
    stream.write_all(b"cat /proc/cpuinfo\n").unwrap();

    // Read all output
    let mut output = String::new();
    let start = std::time::Instant::now();

    while start.elapsed() < Duration::from_secs(2) {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                output.push_str(&String::from_utf8_lossy(&buf[..n]));
                // Give some time for more data to arrive
                thread::sleep(Duration::from_millis(10));

                // Check if we've received enough data
                if output.len() > 500 {
                    // Try to read more with small timeout
                    break;
                }
            }
            Err(_) => break,
        }
    }

    // Try one more read to catch any remaining data
    let start2 = std::time::Instant::now();
    while start2.elapsed() < Duration::from_millis(200) {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                output.push_str(&String::from_utf8_lossy(&buf[..n]));
            }
            Err(_) => break,
        }
    }

    // Verify we got process output (format: process001   user   100)
    assert!(output.contains("process"), "Expected 'process' in output, got: {}", output);

    // Check that we have multiple lines
    let line_count = output.lines().count();
    assert!(line_count >= 10, "Expected at least 10 lines, got: {}\nOutput: {}", line_count, output);

    // Check specific format
    assert!(output.contains("user"));
}

/// Test command that produces error output
#[test]
fn test_execute_command_with_error() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0; 4096];

            // Handle CONNECT
            if let Ok(n) = stream.read(&mut buf) {
                if String::from_utf8_lossy(&buf[..n]).contains("CONNECT") {
                    let _ = stream.write_all(b"OK\n");
                }
            }

            // Read command
            let _ = stream.read(&mut buf);

            // Send error message
            let _ = stream.write_all(b"Error: Command not found\n");
            let _ = stream.write_all(b"Exit code: 127\n");
        }
    });

    thread::sleep(Duration::from_millis(100));

    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("Failed to set timeout");

    // CONNECT
    stream.write_all(b"CONNECT 1025\n").unwrap();
    let mut buf = [0; 1024];
    for _ in 0..10 {
        if let Ok(n) = stream.read(&mut buf) {
            if String::from_utf8_lossy(&buf[..n]).contains("OK") {
                break;
            }
        }
    }

    stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();

    // Send invalid command
    stream.write_all(b"invalid_command\n").unwrap();

    // Read error response
    let mut output = String::new();
    let start = std::time::Instant::now();
    while start.elapsed() < Duration::from_secs(1) {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                output.push_str(&String::from_utf8_lossy(&buf[..n]));
                if output.contains("Exit code") {
                    break;
                }
            }
            Err(_) => break,
        }
    }

    assert!(output.contains("Error"));
    assert!(output.contains("Exit code"));
}

/// Test command with pipeline (|)
#[test]
fn test_execute_command_with_pipeline() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0; 4096];

            // Handle CONNECT
            if let Ok(n) = stream.read(&mut buf) {
                if String::from_utf8_lossy(&buf[..n]).contains("CONNECT") {
                    let _ = stream.write_all(b"OK\n");
                }
            }

            // Read command
            let _ = stream.read(&mut buf);

            // Send filtered output
            let _ = stream.write_all(b"file1.txt\n");
            let _ = stream.write_all(b"file2.log\n");
            let _ = stream.write_all(b"file3.txt\n");
        }
    });

    thread::sleep(Duration::from_millis(100));

    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("Failed to set timeout");

    // CONNECT
    stream.write_all(b"CONNECT 1025\n").unwrap();
    let mut buf = [0; 1024];
    for _ in 0..10 {
        if let Ok(n) = stream.read(&mut buf) {
            if String::from_utf8_lossy(&buf[..n]).contains("OK") {
                break;
            }
        }
    }

    stream.set_read_timeout(None).unwrap();

    // Send command with pipe
    stream.write_all(b"ls | grep txt\n").unwrap();

    // Read response
    let mut output = String::new();
    let start = std::time::Instant::now();
    while start.elapsed() < Duration::from_secs(1) {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                output.push_str(&String::from_utf8_lossy(&buf[..n]));
                if output.contains("file3.txt") {
                    thread::sleep(Duration::from_millis(50));
                    break;
                }
            }
            Err(_) => break,
        }
    }

    assert!(output.contains("file1.txt"));
    assert!(output.contains("file3.txt"));
}

/// Test command execution timing out
#[test]
fn test_command_timeout() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0; 4096];

            // Handle CONNECT
            if let Ok(n) = stream.read(&mut buf) {
                if String::from_utf8_lossy(&buf[..n]).contains("CONNECT") {
                    let _ = stream.write_all(b"OK\n");
                }
            }

            // Read command but don't respond immediately
            let _ = stream.read(&mut buf);

            // Sleep longer than client timeout
            thread::sleep(Duration::from_secs(2));
        }
    });

    thread::sleep(Duration::from_millis(100));

    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    stream
        .set_read_timeout(Some(Duration::from_millis(500)))
        .expect("Failed to set timeout");

    // CONNECT
    stream.write_all(b"CONNECT 1025\n").unwrap();
    let mut buf = [0; 1024];
    for _ in 0..10 {
        if let Ok(n) = stream.read(&mut buf) {
            if String::from_utf8_lossy(&buf[..n]).contains("OK") {
                break;
            }
        }
    }

    // Send command that will timeout
    stream.write_all(b"sleep 10\n").unwrap();

    // Try to read - should timeout
    let start = std::time::Instant::now();
    let mut output = String::new();
    while start.elapsed() < Duration::from_secs(1) {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                output.push_str(&String::from_utf8_lossy(&buf[..n]));
            }
            Err(_) => {
                // Expected timeout
                break;
            }
        }
    }

    // Should have received little to no data due to timeout
    assert!(output.is_empty() || output.len() < 100);
}

/// Test command that produces structured output (JSON-like)
#[test]
fn test_execute_command_with_structured_output() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0; 4096];

            // Handle CONNECT
            if let Ok(n) = stream.read(&mut buf) {
                if String::from_utf8_lossy(&buf[..n]).contains("CONNECT") {
                    let _ = stream.write_all(b"OK\n");
                }
            }

            // Read command
            let _ = stream.read(&mut buf);

            // Send structured output
            let json_output = r#"{"status": "running", "cpu": "45%", "memory": "2GB", "processes": 145}"#;
            let _ = stream.write_all(json_output.as_bytes());
            let _ = stream.write_all(b"\n");
        }
    });

    thread::sleep(Duration::from_millis(100));

    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("Failed to set timeout");

    // CONNECT
    stream.write_all(b"CONNECT 1025\n").unwrap();
    let mut buf = [0; 1024];
    for _ in 0..10 {
        if let Ok(n) = stream.read(&mut buf) {
            if String::from_utf8_lossy(&buf[..n]).contains("OK") {
                break;
            }
        }
    }

    stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();

    // Send command
    stream.write_all(b"status --json\n").unwrap();

    // Read response
    let mut output = String::new();
    let start = std::time::Instant::now();
    while start.elapsed() < Duration::from_secs(1) {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                output.push_str(&String::from_utf8_lossy(&buf[..n]));
                if output.contains("}") {
                    break;
                }
            }
            Err(_) => break,
        }
    }

    assert!(output.contains(r#""status": "running""#));
    assert!(output.contains(r#""cpu": "45%""#));
    assert!(output.contains(r#""memory": "2GB""#));
}
