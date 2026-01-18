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

use anyhow::{Context, Result};
use clap::Parser;
use log::{debug, error, info, warn};
use nix::sys::termios::{tcgetattr, tcsetattr, LocalFlags, OutputFlags, SetArg};
use signal_hook::iterator::Signals;
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const DEFAULT_DEBUG_PORT: u32 = 1025;
const KUASAR_SOCKET_PREFIX: &str = "/run/kuasar";
const CONNECT_TIMEOUT_SECS: u64 = 30;
const MAX_CMD_LENGTH: usize = 4096;

/// Get list of all available pod IDs from the socket directory
pub fn list_available_pods(socket_dir: &str) -> Result<Vec<String>> {
    let dir = Path::new(socket_dir);
    if !dir.exists() {
        return Ok(Vec::new());
    }

    let mut pods = Vec::new();

    for entry in fs::read_dir(dir)
        .with_context(|| format!("Failed to read socket directory {}", socket_dir))?
    {
        let entry = entry?;
        let path = entry.path();

        // Check if task.socket exists in this directory
        let socket_path = path.join("task.socket");
        if socket_path.exists() {
            if let Some(pod_id) = path.file_name().and_then(|n| n.to_str()) {
                pods.push(pod_id.to_string());
            }
        }
    }

    pods.sort();
    Ok(pods)
}

/// Resolve a pod ID prefix to a full pod ID
/// Returns the full pod ID if the prefix uniquely matches one pod
/// Returns an error if no match or multiple matches are found
pub fn resolve_pod_id(socket_dir: &str, pod_prefix: &str) -> Result<String> {
    let available_pods = list_available_pods(socket_dir)?;

    // First, try exact match
    if available_pods.contains(&pod_prefix.to_string()) {
        debug!("Exact match found for pod_id: {}", pod_prefix);
        return Ok(pod_prefix.to_string());
    }

    // Try prefix match
    let matches: Vec<&String> = available_pods
        .iter()
        .filter(|pod| pod.starts_with(pod_prefix))
        .collect();

    match matches.len() {
        0 => {
            let error_msg = if available_pods.is_empty() {
                format!(
                    "No pods found in {}. Please check if any pods are running.",
                    socket_dir
                )
            } else {
                format!(
                    "No pod found with prefix \"{}\". Available pods:\n  {}",
                    pod_prefix,
                    available_pods.join("\n  ")
                )
            };
            Err(anyhow::anyhow!(error_msg))
        }
        1 => {
            let resolved = matches[0].clone();
            info!("Resolved pod prefix \"{}\" to \"{}\"", pod_prefix, resolved);
            Ok(resolved)
        }
        _ => {
            let matches_str: Vec<&str> = matches.iter().map(|s| s.as_str()).collect();
            Err(anyhow::anyhow!(
                "Pod prefix \"{}\" matches multiple pods:\n  {}\nPlease provide a more specific prefix.",
                pod_prefix,
                matches_str.join("\n  ")
            ))
        }
    }
}

/// Kuasar control CLI - Debug and execute commands in Cloud Hypervisor VMs
#[derive(Parser, Debug)]
#[command(name = "kuasarctl")]
#[command(about = "CLI tool for debugging Cloud Hypervisor (CLH) environments", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Parser, Debug)]
enum Commands {
    /// Execute a command in a CLH VM
    Exec {
        /// Pod/Container ID
        pod_id: String,

        /// Command to execute (if not specified, starts an interactive shell)
        command: Vec<String>,

        /// Allocate a pseudo-TTY (for interactive mode)
        #[arg(short = 't', long = "tty")]
        tty: bool,

        /// Keep STDIN open even if not attached (for interactive mode)
        #[arg(short = 'i', long = "interactive")]
        interactive: bool,

        /// Debug console port (default: 1025)
        #[arg(short = 'p', long = "port", default_value_t = DEFAULT_DEBUG_PORT)]
        port: u32,

        /// Socket directory path
        #[arg(short = 'd', long = "socket-dir", default_value = KUASAR_SOCKET_PREFIX)]
        socket_dir: String,
    },
}

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let cli = Cli::parse();

    match cli.command {
        Commands::Exec {
            pod_id,
            command,
            tty,
            interactive,
            port,
            socket_dir,
        } => {
            if let Err(e) = exec_command(pod_id, command, tty, interactive, port, socket_dir) {
                error!("Error: {}", e);
                process::exit(1);
            }
        }
    }
}

fn exec_command(
    pod_id: String,
    command: Vec<String>,
    tty: bool,
    interactive: bool,
    port: u32,
    socket_dir: String,
) -> Result<()> {
    // Resolve pod_id prefix to full pod ID
    let resolved_pod_id = resolve_pod_id(&socket_dir, &pod_id)?;
    let socket_path = format!("{}/{}/task.socket", socket_dir, resolved_pod_id);
    let socket_path_obj = Path::new(&socket_path);

    // Try to connect directly (avoids TOCTOU race condition)
    let mut stream = match UnixStream::connect(&socket_path) {
        Ok(s) => {
            info!("Connected to socket: {}", socket_path);
            s
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            // Provide helpful error message
            let mut hint = String::new();

            // Check if parent directory exists
            if let Some(parent) = socket_path_obj.parent() {
                if !parent.exists() {
                    hint = format!("\nParent directory does not exist: {}", parent.display());
                } else {
                    // List available pods to help user
                    if let Ok(pods) = list_available_pods(&socket_dir) {
                        if !pods.is_empty() {
                            hint = format!("\n\nAvailable pods:\n  {}", pods.join("\n  "));
                        }
                    }
                }
            }

            // Check if path exists but is not a socket
            if socket_path_obj.exists() {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    if let Ok(metadata) = socket_path_obj.metadata() {
                        let mode = metadata.permissions().mode();
                        hint = format!(
                            "{}\nSocket exists but cannot connect. Permissions: {:o}",
                            hint,
                            mode & 0o777
                        );
                    }
                }
            }

            return Err(anyhow::anyhow!(
                "Socket not found or inaccessible: {}{}\n\nTroubleshooting:\n  \
                 1. Check if pod/container is running\n  \
                 2. Check socket directory: ls -la {}\n  \
                 3. Try running with sudo if permission denied",
                socket_path,
                hint,
                socket_dir
            ));
        }
        Err(e) => {
            return Err(anyhow::anyhow!(
                "Failed to connect to socket {}: {}",
                socket_path,
                e
            ));
        }
    };

    // Set timeout for connection
    stream
        .set_read_timeout(Some(Duration::from_secs(CONNECT_TIMEOUT_SECS)))
        .map_err(|e| anyhow::anyhow!("Connected but failed to set read timeout: {}", e))?;
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| anyhow::anyhow!("Connected but failed to set write timeout: {}", e))?;

    // Send CONNECT command
    let connect_cmd = format!("CONNECT {}\n", port);
    debug!("Sending: {}", connect_cmd.trim());

    stream
        .write_all(connect_cmd.as_bytes())
        .context("Failed to send CONNECT command")?;

    // Wait for OK response
    let mut response = Vec::new();
    let mut buf = [0; 4096];
    let mut read_ok = false;

    for _ in 0..10 {
        match stream.read(&mut buf) {
            Ok(0) => {
                thread::sleep(Duration::from_millis(100));
                continue;
            }
            Ok(n) => {
                let chunk = String::from_utf8_lossy(&buf[..n]);
                debug!("Received response: {}", chunk.trim());
                response.extend_from_slice(&buf[..n]);

                if chunk.contains("OK") {
                    read_ok = true;
                    break;
                }
            }
            Err(e) => {
                if e.kind() == io::ErrorKind::WouldBlock {
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
                return Err(anyhow::anyhow!("Failed to read response: {}", e));
            }
        }
    }

    if !read_ok {
        return Err(anyhow::anyhow!(
            "Failed to establish connection. No OK response received."
        ));
    }

    // Remove read timeout for normal operation
    stream.set_read_timeout(None)?;

    // Determine if we should run in interactive mode
    let is_interactive = tty && interactive && command.is_empty();

    if is_interactive {
        // Interactive mode with PTY
        debug!("Starting interactive mode");
        run_interactive_mode(stream)?;
    } else if !command.is_empty() {
        // Non-interactive mode: execute command and exit
        debug!("Executing command: {:?}", command);
        run_non_interactive_mode(stream, command)?;
    } else {
        // Fallback: just copy data without PTY (basic mode)
        debug!("Starting basic mode (no PTY)");
        run_basic_mode(stream)?;
    }

    Ok(())
}

fn run_interactive_mode(mut stream: UnixStream) -> Result<()> {
    let stdin = io::stdin();

    // Use AsFd trait for safe file descriptor access
    let stdin_fd = stdin.as_fd();

    // Safely get current terminal settings
    let original_termios = tcgetattr(stdin_fd)
        .map_err(|e| anyhow::anyhow!("Failed to get terminal attributes: {}", e))?;

    debug!("Original terminal settings retrieved");

    // Set raw mode for terminal (keep ISIG for Ctrl+C)
    let mut raw_termios = original_termios.clone();
    raw_termios.local_flags.remove(LocalFlags::ECHO);
    raw_termios.local_flags.remove(LocalFlags::ICANON);
    // Keep ISIG to allow Ctrl+C to generate SIGINT
    raw_termios.output_flags.insert(OutputFlags::OPOST);

    tcsetattr(stdin_fd, SetArg::TCSANOW, &raw_termios)
        .map_err(|e| anyhow::anyhow!("Failed to set raw mode: {}", e))?;

    info!("Terminal set to raw mode (Ctrl+C to exit)");

    // Create shared stop flag for graceful shutdown
    let stop_flag = Arc::new(Mutex::new(false));
    let stop_flag_clone = Arc::clone(&stop_flag);
    let stop_flag_outer = Arc::clone(&stop_flag);
    let stop_flag_signal = Arc::clone(&stop_flag);

    // Set up signal handling for Ctrl+C
    let sigint = 2; // SIGINT
    let mut signals = Signals::new([sigint])
        .map_err(|e| anyhow::anyhow!("Failed to create signal handler: {}", e))?;

    let signal_handle = thread::spawn(move || {
        for sig in &mut signals {
            if sig == sigint {
                info!("Ctrl+C received, shutting down gracefully...");
                *stop_flag_signal.lock().unwrap() = true;
                break;
            }
        }
    });

    info!("SIGINT handler registered (Ctrl+C to exit)");

    // Use scopeguard to ensure terminal settings are restored
    let stdin_fd_guard = stdin_fd.clone();
    let _restore = scopeguard::guard(&original_termios, move |termios| {
        // Restore terminal settings
        if let Err(e) = tcsetattr(stdin_fd_guard, SetArg::TCSANOW, termios) {
            // Log to stderr since stdout might be in bad state
            eprintln!("\n\x1b[1;31m[ERROR]\x1b[0m Failed to restore terminal settings: {}", e);
            eprintln!("\x1b[1;33m[WARN]\x1b[0m Your terminal may be in an inconsistent state.");
            eprintln!("\x1b[1mTry running one of these commands to fix:\x1b[0m");
            eprintln!("  - \x1b[1mreset\x1b[0m");
            eprintln!("  - \x1b[1mstty sane\x1b[0m");
        } else {
            debug!("Terminal settings restored successfully");
        }
    });

    // Spawn threads for bidirectional copying
    let mut stream_clone = stream.try_clone()
        .map_err(|e| anyhow::anyhow!("Failed to clone socket: {}", e))?;

    let stdin_handle = thread::spawn(move || {
        let mut stdin = io::stdin();
        let mut buf = [0; 1024];

        loop {
            // Check for stop signal
            if *stop_flag.lock().unwrap() {
                debug!("stdin thread received stop signal");
                break;
            }

            match stdin.read(&mut buf) {
                Ok(0) => {
                    debug!("stdin closed");
                    break;
                }
                Ok(n) => {
                    if stream_clone.write_all(&buf[..n]).is_err() {
                        warn!("Failed to write to socket");
                        break;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {
                    continue;
                }
                Err(e) => {
                    error!("stdin read error: {}", e);
                    break;
                }
            }
        }
    });

    let stdout_handle = thread::spawn(move || {
        let mut stdout = io::stdout();
        let mut buf = [0; 4096];

        loop {
            // Check for stop signal
            if *stop_flag_clone.lock().unwrap() {
                debug!("stdout thread received stop signal");
                break;
            }

            match stream.read(&mut buf) {
                Ok(0) => {
                    debug!("socket closed");
                    break;
                }
                Ok(n) => {
                    if stdout.write_all(&buf[..n]).is_err() {
                        warn!("Failed to write to stdout");
                        break;
                    }
                    if stdout.flush().is_err() {
                        warn!("Failed to flush stdout");
                        break;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {
                    continue;
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    continue;
                }
                Err(e) => {
                    error!("socket read error: {}", e);
                    break;
                }
            }
        }
    });

    // Wait for stdin thread to finish
    let _ = stdin_handle.join();

    // Signal stdout thread to stop
    *stop_flag_outer.lock().unwrap() = true;

    let _ = stdout_handle.join();

    // Wait for signal handler thread to finish
    let _ = signal_handle.join();

    // Explicitly restore terminal (guard will also do this, but be explicit)
    drop(_restore);

    debug!("Interactive session ended");
    Ok(())
}

fn run_non_interactive_mode(mut stream: UnixStream, command: Vec<String>) -> Result<()> {
    // Validate and send the command
    let cmd_line = command.join(" ");

    // Input validation
    if cmd_line.contains('\0') {
        return Err(anyhow::anyhow!("Command contains null byte, which is not allowed"));
    }

    if cmd_line.len() > MAX_CMD_LENGTH {
        return Err(anyhow::anyhow!(
            "Command too long: {} bytes (max: {} bytes)",
            cmd_line.len(),
            MAX_CMD_LENGTH
        ));
    }

    // Warn about potential escape sequences (unless using grep/sed)
    if cmd_line.contains("\\x1b") && !cmd_line.contains("grep") && !cmd_line.contains("sed") {
        warn!("Command contains ANSI escape sequences which may not work correctly");
    }

    writeln!(stream, "{}", cmd_line).context("Failed to send command")?;
    debug!("Command sent: {}", cmd_line);

    // Read response
    let mut stdout = io::stdout();
    let mut buf = [0; 4096];
    loop {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                stdout.write_all(&buf[..n])?;
                stdout.flush()?;
            }
            Err(e) => {
                if e.kind() == io::ErrorKind::WouldBlock {
                    continue;
                }
                break;
            }
        }
    }

    Ok(())
}

fn run_basic_mode(mut stream: UnixStream) -> Result<()> {
    // Simple bidirectional copy without PTY
    let mut stream_clone = stream.try_clone()
        .map_err(|e| anyhow::anyhow!("Failed to clone socket: {}", e))?;

    // Create shared stop flag for graceful shutdown
    let stop_flag = Arc::new(Mutex::new(false));
    let stop_flag_clone = Arc::clone(&stop_flag);
    let stop_flag_outer = Arc::clone(&stop_flag);
    let stop_flag_signal = Arc::clone(&stop_flag);

    // Set up signal handling for Ctrl+C
    let sigint = 2; // SIGINT
    let mut signals = Signals::new([sigint])
        .map_err(|e| anyhow::anyhow!("Failed to create signal handler: {}", e))?;

    let signal_handle = thread::spawn(move || {
        for sig in &mut signals {
            if sig == sigint {
                info!("Ctrl+C received, shutting down gracefully...");
                *stop_flag_signal.lock().unwrap() = true;
                break;
            }
        }
    });

    info!("Basic mode started (Ctrl+C to exit)");

    let stdin_handle = thread::spawn(move || {
        let mut stdin = io::stdin();
        let mut buf = [0; 1024];

        loop {
            // Check for stop signal
            if *stop_flag.lock().unwrap() {
                debug!("stdin thread received stop signal");
                break;
            }

            match stdin.read(&mut buf) {
                Ok(0) => {
                    debug!("stdin closed");
                    break;
                }
                Ok(n) => {
                    if stream_clone.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {
                    continue;
                }
                Err(_) => break,
            }
        }
    });

    let stdout_handle = thread::spawn(move || {
        let mut stdout = io::stdout();
        let mut buf = [0; 4096];

        loop {
            // Check for stop signal
            if *stop_flag_clone.lock().unwrap() {
                debug!("stdout thread received stop signal");
                break;
            }

            match stream.read(&mut buf) {
                Ok(0) => {
                    debug!("socket closed");
                    break;
                }
                Ok(n) => {
                    if stdout.write_all(&buf[..n]).is_err() {
                        break;
                    }
                    let _ = stdout.flush();
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {
                    continue;
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    continue;
                }
                Err(_) => break,
            }
        }
    });

    // Wait for stdin thread to finish
    let _ = stdin_handle.join();

    // Signal stdout thread to stop
    *stop_flag_outer.lock().unwrap() = true;

    let _ = stdout_handle.join();

    // Wait for signal handler thread to finish
    let _ = signal_handle.join();

    debug!("Basic mode session ended");
    Ok(())
}
