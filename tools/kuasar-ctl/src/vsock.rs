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

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use anyhow::{anyhow, Context};
use log::debug;

use crate::error::{KuasarCtlError, Result};

const CMD_CONNECT: &str = "CONNECT";
const CMD_OK: &str = "OK";
const KATA_AGENT_VSOCK_TIMEOUT: u64 = 5;

/// Connect to an hvsock socket
pub fn connect_hvsock(socket_path: &Path, port: u32) -> Result<UnixStream> {
    debug!(
        "Connecting to hvsock socket: {} port {}",
        socket_path.display(),
        port
    );

    let mut stream = UnixStream::connect(socket_path).context(format!(
        "failed to connect to hvsock socket: {}",
        socket_path.display()
    ))?;

    debug!("Unix socket connection established");

    // Send CONNECT command
    let test_msg = format!("{} {}\n", CMD_CONNECT, port);
    debug!("Sending CONNECT command: {}", test_msg.trim());

    let timeout = Duration::from_secs(KATA_AGENT_VSOCK_TIMEOUT);
    stream
        .set_read_timeout(Some(timeout))
        .context("set read timeout")?;
    stream
        .set_write_timeout(Some(timeout))
        .context("set write timeout")?;

    stream
        .write_all(test_msg.as_bytes())
        .context("write CONNECT command")?;

    debug!("CONNECT command sent, waiting for response");

    // Read response
    let stream_reader = stream.try_clone().context("clone stream")?;
    let mut reader = BufReader::new(&stream_reader);
    let mut msg = String::new();

    reader
        .read_line(&mut msg)
        .context("read response from hvsock")?;

    debug!("Received response: {}", msg.trim());

    if msg.is_empty() {
        return Err(KuasarCtlError::VsockConnectionFailed(anyhow!(
            "empty response from hvsock port: {:?}",
            port
        )));
    }

    // Expected response message returned was successful.
    if msg.starts_with(CMD_OK) {
        debug!("Connection established successfully");
        // Unset the timeout in order to turn the socket to blocking mode.
        stream.set_read_timeout(None).context("unset read timeout")?;
        stream
            .set_write_timeout(None)
            .context("unset write timeout")?;
    } else {
        debug!("Connection failed with response: {}", msg.trim());
        return Err(KuasarCtlError::VsockConnectionFailed(anyhow!(
            "failed to setup hvsock connection: {:?}",
            msg
        )));
    }

    Ok(stream)
}
