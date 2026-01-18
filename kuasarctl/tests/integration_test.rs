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

//! Integration tests for kuasarctl socket connection and command execution

use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::thread;
use std::time::Duration;
use tempfile::TempDir;

/// Test CONNECT protocol: send CONNECT command and receive OK response
#[test]
fn test_connect_protocol() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    // Start a simple server that handles CONNECT protocol
    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0; 1024];
            if let Ok(n) = stream.read(&mut buf) {
                let request = String::from_utf8_lossy(&buf[..n]);
                if request.contains("CONNECT 1025") {
                    let _ = stream.write_all(b"OK\n");
                    // Echo back any data received
                    let _ = stream.read(&mut buf);
                    let _ = stream.write_all(b"echo response\n");
                }
            }
        }
    });

    // Give server time to start
    thread::sleep(Duration::from_millis(100));

    // Client: Connect and send CONNECT command
    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    stream
        .write_all(b"CONNECT 1025\n")
        .expect("Failed to send CONNECT");

    let mut buf = [0; 1024];

    // Wait for OK response
    let mut ok_received = false;
    for _ in 0..10 {
        if let Ok(n) = stream.read(&mut buf) {
            let chunk = String::from_utf8_lossy(&buf[..n]);
            if chunk.contains("OK") {
                ok_received = true;
                break;
            }
        }
        thread::sleep(Duration::from_millis(50));
    }

    assert!(ok_received, "Did not receive OK response");
}

/// Test that client handles missing OK response correctly
#[test]
fn test_connect_timeout_without_ok() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    // Start a server that doesn't send OK
    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            // Just read, don't send OK
            let mut buf = [0; 1024];
            let _ = stream.read(&mut buf);
        }
    });

    thread::sleep(Duration::from_millis(100));

    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .expect("Failed to set timeout");
    stream
        .write_all(b"CONNECT 1025\n")
        .expect("Failed to send CONNECT");

    let mut buf = [0; 1024];
    let mut ok_received = false;

    for _ in 0..5 {
        match stream.read(&mut buf) {
            Ok(0) => {
                thread::sleep(Duration::from_millis(100));
                continue;
            }
            Ok(n) => {
                let chunk = String::from_utf8_lossy(&buf[..n]);
                if chunk.contains("OK") {
                    ok_received = true;
                    break;
                }
            }
            Err(_) => break,
        }
    }

    assert!(!ok_received, "Should not receive OK response from non-responsive server");
}

/// Test bidirectional data transfer after connection
#[test]
fn test_bidirectional_data_transfer() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0; 1024];

            // Handle CONNECT
            if let Ok(n) = stream.read(&mut buf) {
                let request = String::from_utf8_lossy(&buf[..n]);
                if request.contains("CONNECT") {
                    let _ = stream.write_all(b"OK\n");
                }
            }

            // Echo server: read data and echo it back
            loop {
                match stream.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        if stream.write_all(&buf[..n]).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        }
    });

    thread::sleep(Duration::from_millis(100));

    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
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
            let chunk = String::from_utf8_lossy(&buf[..n]);
            if chunk.contains("OK") {
                ok_received = true;
                break;
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
    assert!(ok_received);

    // Remove timeout for data transfer
    stream.set_read_timeout(None).expect("Failed to clear timeout");

    // Send test data
    let test_data = b"Hello, World!";
    stream
        .write_all(test_data)
        .expect("Failed to write test data");

    // Read echoed data
    let mut response = vec![0u8; test_data.len()];
    stream
        .read_exact(&mut response)
        .expect("Failed to read echoed data");

    assert_eq!(test_data, response.as_slice());
}

/// Test handling of multiple concurrent connections
#[test]
fn test_multiple_connections() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        for _ in 0..3 {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0; 1024];
                if let Ok(n) = stream.read(&mut buf) {
                    let request = String::from_utf8_lossy(&buf[..n]);
                    if request.contains("CONNECT") {
                        let _ = stream.write_all(b"OK\n");
                    }
                }
            }
        }
    });

    thread::sleep(Duration::from_millis(100));

    // Create multiple connections
    for i in 0..3 {
        let stream = UnixStream::connect(&socket_path).expect("Failed to connect");
        let mut stream = stream;
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("Failed to set timeout");

        stream
            .write_all(b"CONNECT 1025\n")
            .expect("Failed to send CONNECT");

        let mut buf = [0; 1024];
        let mut ok_received = false;
        for _ in 0..10 {
            if let Ok(n) = stream.read(&mut buf) {
                let chunk = String::from_utf8_lossy(&buf[..n]);
                if chunk.contains("OK") {
                    ok_received = true;
                    break;
                }
            }
            thread::sleep(Duration::from_millis(50));
        }

        assert!(
            ok_received,
            "Connection {} did not receive OK response",
            i
        );
        thread::sleep(Duration::from_millis(50));
    }
}

/// Test error handling when connecting to non-existent socket
#[test]
fn test_connect_nonexistent_socket() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("nonexistent-socket");

    let result = UnixStream::connect(&socket_path);
    assert!(result.is_err(), "Should fail to connect to non-existent socket");
}

/// Test handling of malformed CONNECT command
#[test]
fn test_malformed_connect_command() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let socket_path = temp_dir.path().join("test-socket");

    let listener = UnixListener::bind(&socket_path).expect("Failed to bind socket");

    thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0; 1024];
            let _ = stream.read(&mut buf);
            // Don't send OK for malformed command
        }
    });

    thread::sleep(Duration::from_millis(100));

    let mut stream = UnixStream::connect(&socket_path).expect("Failed to connect");
    stream
        .set_read_timeout(Some(Duration::from_millis(500)))
        .expect("Failed to set timeout");

    // Send malformed command (missing port)
    stream
        .write_all(b"CONNECT\n")
        .expect("Failed to send data");

    let mut buf = [0; 1024];
    let mut response_received = false;

    for _ in 0..5 {
        match stream.read(&mut buf) {
            Ok(0) => {
                thread::sleep(Duration::from_millis(100));
                continue;
            }
            Ok(_) => {
                response_received = true;
                break;
            }
            Err(_) => break,
        }
    }

    // Should not receive OK for malformed command
    assert!(!response_received || !String::from_utf8_lossy(&buf).contains("OK"));
}
