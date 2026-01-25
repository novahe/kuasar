/*
Copyright 2022 The Kuasar Authors.

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

mod args;
mod error;
mod interactive;
mod sandbox;
mod vsock;

use clap::Parser;
use std::process::exit;

use args::{Cli, Commands};
use error::Result;
use interactive::execute_interactive;
use sandbox::find_sandbox;
use vsock::connect_hvsock;

fn main() {
    let cli = Cli::parse();

    // Initialize logging based on verbose level
    init_logging(cli.verbose);

    // Print version info in verbose mode
    if cli.verbose > 0 {
        print_version_info();
    }

    // Execute command
    if let Err(e) = run(cli) {
        eprintln!("Error: {}", e);
        exit(e.exit_code());
    }
}

fn init_logging(verbose: u8) {
    let log_level = match verbose {
        0 => "warn",
        1 => "info",
        2 => "debug",
        _ => "trace",
    };

    if let Err(e) = env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or(log_level)
    )
    .format_timestamp_secs()
    .try_init()
    {
        eprintln!("Failed to initialize logger: {}", e);
    }
}

fn print_version_info() {
    eprintln!("kuasar-ctl version information:");
    eprintln!("  Version: {}", env!("CARGO_PKG_VERSION"));
    eprintln!("  Commit: {}", env!("KUASAR_CTL_COMMIT_HASH"));
    eprintln!("  Short: {}", env!("KUASAR_CTL_COMMIT_SHORT"));
    eprintln!("  Date: {}", env!("KUASAR_CTL_COMMIT_DATE"));
    eprintln!("  Message: {}", env!("KUASAR_CTL_COMMIT_MSG"));
    eprintln!();
}

fn run(cli: Cli) -> Result<()> {
    match cli.command {
        Commands::Exec(args) => exec_command(args, cli.verbose),
    }
}

fn exec_command(args: args::ExecArgs, verbose: u8) -> Result<()> {
    if verbose > 0 {
        eprintln!("Connecting to pod: {}", args.pod_id);
        eprintln!("Port: {}", args.port);
    }

    // Find sandbox
    let sandbox = find_sandbox(&args.pod_id)?;
    if verbose > 0 {
        eprintln!("Found sandbox: {}", sandbox.pod_id);
        eprintln!("Socket: {}", sandbox.vsock_socket.display());
    }

    // Connect to hvsock using CONNECT protocol
    let stream = connect_hvsock(&sandbox.vsock_socket, args.port)?;

    if verbose > 0 {
        eprintln!("Connected successfully, starting interactive session...");
    }

    // Execute interactive session (like kata-containers)
    execute_interactive(stream)?;

    Ok(())
}
