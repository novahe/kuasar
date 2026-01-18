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

//! Library for kuasarctl functionality

pub use main::{list_available_pods, resolve_pod_id};

// Include the main module
mod main {
    //! Main module with public functions re-exported

    use anyhow::{Context, Result};
    use std::fs;
    use std::path::Path;

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
}
