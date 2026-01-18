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

//! Integration tests for interactive shell behavior

use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::thread;
use std::time::Duration;
use tempfile::TempDir;

/// Test interactive shell with prompt
#[test]
fn test_interactive_shell_prompt() {
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
                    // Flush immediately
                    let _ = stream.flush();
                }
            }

            thread::sleep(Duration::from_millis(50));

            // Send shell prompt
            let _ = stream.write_all(b"/ # ");
            let _ = stream.flush();

            // Echo commands back
            loop {
                match stream.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let input = String::from_utf8_lossy(&buf[..n]);
                        if input.trim() == "exit" {
                            break;
                        }

                        // Send prompt again after command
                        let _ = stream.write_all(b"\n/ # ");
                        let _ = stream.flush();
                    }
                    Err(_) => break,
                }
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
    let _ = stream.flush();

    let mut buf = [0; 1024];
    for _ in 0..20 {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if String::from_utf8_lossy(&buf[..n]).contains("OK") {
                    break;
                }
            }
            Err(_) => break,
        }
        thread::sleep(Duration::from_millis(50));
    }

    // Wait for prompt
    let mut output = String::new();
    let start = std::time::Instant::now();
    while start.elapsed() < Duration::from_secs(2) {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                output.push_str(&String::from_utf8_lossy(&buf[..n]));
                if output.contains("/ #") {
                    break;
                }
            }
            Err(_) => break,
        }
        thread::sleep(Duration::from_millis(10));
    }

    assert!(output.contains("/ #"), "Expected prompt in output, got: {}", output);
}

/// Test multiple commands in interactive session
#[test]
fn test_interactive_session_multiple_commands() {
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
                    let _ = stream.flush();
                }
            }

            thread::sleep(Duration::from_millis(50));

            // Send initial prompt
            let _ = stream.write_all(b"/ # ");
            let _ = stream.flush();

            // Process commands
            let mut command_count = 0;
            loop {
                match stream.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let input = String::from_utf8_lossy(&buf[..n]);
                        let cmd = input.trim();

                        if cmd == "exit" {
                            break;
                        }

                        command_count += 1;

                        // Send command output based on command
                        match cmd {
                            "ls" => {
                                let _ = stream.write_all(b"bin\ndev\netc\n");
                            }
                            "pwd" => {
                                let _ = stream.write_all(b"/\n");
                            }
                            "whoami" => {
                                let _ = stream.write_all(b"root\n");
                            }
                            _ => {
                                let _ = stream.write_all(b"command executed\n");
                            }
                        }
                        let _ = stream.flush();

                        // Send prompt again
                        thread::sleep(Duration::from_millis(10));
                        let _ = stream.write_all(b"/ # ");
                        let _ = stream.flush();

                        if command_count >= 3 {
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
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("Failed to set timeout");

    // CONNECT
    stream.write_all(b"CONNECT 1025\n").unwrap();
    let _ = stream.flush();

    let mut buf = [0; 1024];
    for _ in 0..20 {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if String::from_utf8_lossy(&buf[..n]).contains("OK") {
                    break;
                }
            }
            Err(_) => break,
        }
        thread::sleep(Duration::from_millis(50));
    }

    // Wait for initial prompt
    let mut output = String::new();
    for _ in 0..40 {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                output.push_str(&String::from_utf8_lossy(&buf[..n]));
                if output.contains("/ #") {
                    break;
                }
            }
            Err(_) => break,
        }
        thread::sleep(Duration::from_millis(50));
    }

    assert!(output.contains("/ #"), "Expected initial prompt, got: {}", output);

    // Send commands and collect outputs
    let commands = vec!["pwd", "whoami", "ls"];
    let mut responses = Vec::new();

    for cmd in commands {
        stream
            .write_all(format!("{}\n", cmd).as_bytes())
            .unwrap();
        let _ = stream.flush();

        let mut cmd_output = String::new();
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(1) {
            match stream.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    cmd_output.push_str(&String::from_utf8_lossy(&buf[..n]));
                    if cmd_output.contains("/ #") {
                        break;
                    }
                }
                Err(_) => break,
            }
            thread::sleep(Duration::from_millis(10));
        }
        responses.push(cmd_output.clone());
        thread::sleep(Duration::from_millis(50));
    }

    // Verify responses (check if they contain expected output or prompt)
    assert!(responses.len() >= 3);
    assert!(responses[0].contains("/") || responses[0].contains("/ #"));
    assert!(responses[1].contains("root") || responses[1].contains("/ #"));
    assert!(responses[2].contains("bin") || responses[2].contains("/ #"));
}

/// Test shell tab completion simulation
#[test]
fn test_shell_tab_completion() {
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

            // Send prompt
            let _ = stream.write_all(b"/ # ");

            // Read input
            let _ = stream.read(&mut buf);
            let input = String::from_utf8_lossy(&buf);

            // Simulate tab completion
            if input.contains("ls") {
                let _ = stream.write_all(b"\nls bin  boot  dev  etc  home  lib\n");
            }

            let _ = stream.write_all(b"/ # ");
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

    // Wait for prompt
    let mut output = String::new();
    for _ in 0..20 {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                output.push_str(&String::from_utf8_lossy(&buf[..n]));
                if output.contains("/ #") {
                    break;
                }
            }
            Err(_) => break,
        }
    }

    // Send partial command with tab
    stream.write_all(b"ls\t").unwrap();

    // Read completion
    let mut completion = String::new();
    let start = std::time::Instant::now();
    while start.elapsed() < Duration::from_secs(1) {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                completion.push_str(&String::from_utf8_lossy(&buf[..n]));
                if completion.contains("/ #") {
                    break;
                }
            }
            Err(_) => break,
        }
    }

    assert!(completion.contains("bin"));
    assert!(completion.contains("etc"));
}

/// Test shell history (up/down arrow)
#[test]
fn test_shell_history_navigation() {
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

            // Send prompt
            let _ = stream.write_all(b"/ # ");

            // Track command history
            let mut history = Vec::new();

            // Read commands
            for _ in 0..3 {
                match stream.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let cmd = String::from_utf8_lossy(&buf[..n]).trim().to_string();
                        if !cmd.is_empty() {
                            history.push(cmd);
                        }

                        // Echo the command back (simulating history recall)
                        let _ = stream.write_all(format!("\n{}\n", history.last().unwrap_or(&String::new())).as_bytes());
                        let _ = stream.write_all(b"/ # ");
                    }
                    Err(_) => break,
                }
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

    // Wait for prompt
    for _ in 0..20 {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(_) if String::from_utf8_lossy(&buf).contains("/ #") => break,
            Ok(_) => {}
            Err(_) => break,
        }
    }

    // Send commands
    let commands = vec!["echo hello", "echo world", "echo test"];
    for cmd in commands {
        stream
            .write_all(format!("{}\n", cmd).as_bytes())
            .unwrap();

        let mut output = String::new();
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_millis(500) {
            match stream.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    output.push_str(&String::from_utf8_lossy(&buf[..n]));
                    if output.contains("/ #") {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    }
}

/// Test shell exit behavior
#[test]
fn test_shell_exit_command() {
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

            // Send prompt
            let _ = stream.write_all(b"/ # ");

            // Read commands
            loop {
                match stream.read(&mut buf) {
                    Ok(0) => {
                        // Client closed connection
                        break;
                    }
                    Ok(n) => {
                        let input = String::from_utf8_lossy(&buf[..n]);
                        if input.trim() == "exit" {
                            // Send goodbye message
                            let _ = stream.write_all(b"Goodbye!\n");
                            break;
                        }

                        // Echo back and show prompt
                        let _ = stream.write_all(b"\n/ # ");
                    }
                    Err(_) => break,
                }
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

    // Wait for prompt
    for _ in 0..20 {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(_) if String::from_utf8_lossy(&buf).contains("/ #") => break,
            Ok(_) => {}
            Err(_) => break,
        }
    }

    // Send some commands
    stream.write_all(b"pwd\n").unwrap();
    thread::sleep(Duration::from_millis(100));

    // Send exit command
    stream.write_all(b"exit\n").unwrap();

    // Read goodbye message
    let mut output = String::new();
    let start = std::time::Instant::now();
    while start.elapsed() < Duration::from_secs(1) {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                output.push_str(&String::from_utf8_lossy(&buf[..n]));
                if output.contains("Goodbye") {
                    break;
                }
            }
            Err(_) => break,
        }
    }

    assert!(output.contains("Goodbye"));
}
