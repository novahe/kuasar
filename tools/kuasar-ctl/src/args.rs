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

use clap::{Parser, Subcommand};

#[derive(Parser, Debug)]
#[command(name = "kuasar-ctl")]
#[command(author = "The Kuasar Authors")]
#[command(version = env!("KUASAR_CTL_COMMIT_SHORT"))]
#[command(about = "Kuasar control and debugging tool", long_about = None)]
pub struct Cli {
    /// Enable verbose output (-v for normal, -vv for more debug)
    #[arg(short, long, action = clap::ArgAction::Count)]
    pub verbose: u8,

    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand, Debug)]
pub enum Commands {
    /// Execute a command in a pod's debug console
    Exec(ExecArgs),
}

#[derive(clap::Args, Debug)]
pub struct ExecArgs {
    /// Pod/sandbox ID
    #[arg(value_name = "POD_ID")]
    pub pod_id: String,

    /// Debug console vsock port
    #[arg(short = 'p', long, default_value = "1025")]
    pub port: u32,
}
