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

use std::fs;
use std::path::{Path, PathBuf};

use log::debug;

use crate::error::{KuasarCtlError, Result};

#[derive(Debug, Clone)]
pub struct SandboxInfo {
    pub pod_id: String,
    pub vsock_socket: PathBuf,
}

/// Find sandbox information by pod ID (supports prefix matching)
pub fn find_sandbox(pod_id: &str) -> Result<SandboxInfo> {
    const SANDBOX_BASE: &str = "/run/kuasar-vmm";

    debug!("Searching for sandbox with pod ID: {}", pod_id);

    // Try exact match first
    let exact_path = PathBuf::from(SANDBOX_BASE).join(pod_id).join("task.vsock");
    debug!("Checking exact path: {}", exact_path.display());
    if exact_path.exists() {
        debug!("Found exact match for pod: {}", pod_id);
        return Ok(SandboxInfo {
            pod_id: pod_id.to_string(),
            vsock_socket: exact_path,
        });
    }

    // Try prefix matching
    let sandbox_base = Path::new(SANDBOX_BASE);
    if !sandbox_base.exists() {
        debug!("Sandbox base directory does not exist: {}", SANDBOX_BASE);
        return Err(KuasarCtlError::SandboxNotFound(pod_id.to_string()));
    }

    let entries = fs::read_dir(sandbox_base).map_err(|e| {
        KuasarCtlError::IoError(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("failed to read sandbox directory: {}", e),
        ))
    })?;

    let mut matches: Vec<String> = Vec::with_capacity(8);

    for entry in entries {
        let entry = entry.map_err(|e| {
            KuasarCtlError::IoError(std::io::Error::new(
                std::io::ErrorKind::Other,
                format!("failed to read directory entry: {}", e),
            ))
        })?;
        let file_name = entry.file_name();
        let name = file_name.to_string_lossy();

        if name.starts_with(pod_id) {
            let vsock_path = entry.path().join("task.vsock");
            debug!("Checking prefix match: {} -> {}", name, vsock_path.display());
            if vsock_path.exists() {
                debug!("Found valid sandbox: {}", name);
                matches.push(name.into_owned());
            }
        }
    }

    if matches.is_empty() {
        debug!("No matching sandbox found for: {}", pod_id);
        return Err(KuasarCtlError::SandboxNotFound(pod_id.to_string()));
    }

    if matches.len() > 1 {
        debug!("Multiple matches found for: {}: {:?}", pod_id, matches);
        return Err(KuasarCtlError::SandboxNotFound(format!(
            "{} (multiple matches: {})",
            pod_id,
            matches.join(", ")
        )));
    }

    let matched_pod_id = &matches[0];
    let vsock_socket = PathBuf::from(SANDBOX_BASE).join(matched_pod_id).join("task.vsock");

    debug!("Returning sandbox info: {} -> {}", matched_pod_id, vsock_socket.display());

    Ok(SandboxInfo {
        pod_id: matched_pod_id.clone(),
        vsock_socket,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_prefix_matching_logic() {
        // Test prefix matching behavior
        let test_pods = vec![
            "pod-abc-123",
            "pod-abc-456",
            "pod-xyz-789",
        ];

        // Test unique prefix match
        let prefix = "pod-xyz";
        let matches: Vec<&str> = test_pods
            .iter()
            .filter(|p| p.starts_with(prefix))
            .copied()
            .collect();
        assert_eq!(matches, vec!["pod-xyz-789"]);

        // Test multiple matches
        let prefix = "pod-abc";
        let matches: Vec<&str> = test_pods
            .iter()
            .filter(|p| p.starts_with(prefix))
            .copied()
            .collect();
        assert_eq!(matches.len(), 2);

        // Test no match
        let prefix = "pod-notfound";
        let matches: Vec<&str> = test_pods
            .iter()
            .filter(|p| p.starts_with(prefix))
            .copied()
            .collect();
        assert!(matches.is_empty());
    }

    #[test]
    fn test_sandbox_info_creation() {
        let info = SandboxInfo {
            pod_id: "test-pod".to_string(),
            vsock_socket: PathBuf::from("/run/kuasar-vmm/test-pod/task.vsock"),
        };
        assert_eq!(info.pod_id, "test-pod");
        assert_eq!(info.vsock_socket, PathBuf::from("/run/kuasar-vmm/test-pod/task.vsock"));
    }
}
