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

//! Unit tests for prefix matching functionality

use std::fs;
use std::os::unix::net::UnixListener;
use tempfile::TempDir;

// Re-import the functions we want to test
use kuasarctl::list_available_pods;
use kuasarctl::resolve_pod_id;

#[test]
fn test_list_available_pods_empty_directory() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");
    let pods = list_available_pods(temp_dir.path().to_str().unwrap()).unwrap();
    assert_eq!(pods.len(), 0);
}

#[test]
fn test_list_available_pods_with_valid_sockets() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    // Create pod directories with task.socket files
    let pod_dirs = vec!["pod-001", "pod-002", "pod-abc-123"];
    for pod_id in &pod_dirs {
        let pod_path = temp_dir.path().join(pod_id);
        fs::create_dir(&pod_path).expect("Failed to create pod dir");
        let socket_path = pod_path.join("task.socket");
        UnixListener::bind(&socket_path).expect("Failed to create socket");
    }

    let pods = list_available_pods(temp_dir.path().to_str().unwrap()).unwrap();
    assert_eq!(pods.len(), 3);
    assert!(pods.contains(&"pod-001".to_string()));
    assert!(pods.contains(&"pod-002".to_string()));
    assert!(pods.contains(&"pod-abc-123".to_string()));
}

#[test]
fn test_list_available_pods_ignores_dirs_without_socket() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    // Create directories without task.socket
    fs::create_dir(temp_dir.path().join("pod-001")).expect("Failed to create pod dir");
    fs::create_dir(temp_dir.path().join("pod-002")).expect("Failed to create pod dir");

    let pods = list_available_pods(temp_dir.path().to_str().unwrap()).unwrap();
    assert_eq!(pods.len(), 0);
}

#[test]
fn test_list_available_pods_sorted() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    // Create pods in non-alphabetical order
    let pod_ids = vec!["pod-003", "pod-001", "pod-002"];
    for pod_id in &pod_ids {
        let pod_path = temp_dir.path().join(pod_id);
        fs::create_dir(&pod_path).expect("Failed to create pod dir");
        let socket_path = pod_path.join("task.socket");
        UnixListener::bind(&socket_path).expect("Failed to create socket");
    }

    let pods = list_available_pods(temp_dir.path().to_str().unwrap()).unwrap();
    assert_eq!(pods, vec!["pod-001", "pod-002", "pod-003"]);
}

#[test]
fn test_resolve_pod_id_exact_match() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    // Create pod
    let pod_path = temp_dir.path().join("pod-abc-123");
    fs::create_dir(&pod_path).expect("Failed to create pod dir");
    let socket_path = pod_path.join("task.socket");
    UnixListener::bind(&socket_path).expect("Failed to create socket");

    let resolved = resolve_pod_id(temp_dir.path().to_str().unwrap(), "pod-abc-123");
    assert!(resolved.is_ok());
    assert_eq!(resolved.unwrap(), "pod-abc-123");
}

#[test]
fn test_resolve_pod_id_unique_prefix() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    // Create pods
    let pod_ids = vec!["pod-abc-123", "pod-xyz-789", "pod-def-456"];
    for pod_id in &pod_ids {
        let pod_path = temp_dir.path().join(pod_id);
        fs::create_dir(&pod_path).expect("Failed to create pod dir");
        let socket_path = pod_path.join("task.socket");
        UnixListener::bind(&socket_path).expect("Failed to create socket");
    }

    let resolved = resolve_pod_id(temp_dir.path().to_str().unwrap(), "pod-abc");
    assert!(resolved.is_ok());
    assert_eq!(resolved.unwrap(), "pod-abc-123");
}

#[test]
fn test_resolve_pod_id_multiple_matches_error() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    // Create pods with same prefix
    let pod_ids = vec!["pod-abc-123", "pod-abc-456"];
    for pod_id in &pod_ids {
        let pod_path = temp_dir.path().join(pod_id);
        fs::create_dir(&pod_path).expect("Failed to create pod dir");
        let socket_path = pod_path.join("task.socket");
        UnixListener::bind(&socket_path).expect("Failed to create socket");
    }

    let resolved = resolve_pod_id(temp_dir.path().to_str().unwrap(), "pod-abc");
    assert!(resolved.is_err());
    let error_msg = resolved.unwrap_err().to_string();
    assert!(error_msg.contains("matches multiple pods"));
    assert!(error_msg.contains("pod-abc-123"));
    assert!(error_msg.contains("pod-abc-456"));
}

#[test]
fn test_resolve_pod_id_no_match_error() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    // Create pod
    let pod_path = temp_dir.path().join("pod-abc-123");
    fs::create_dir(&pod_path).expect("Failed to create pod dir");
    let socket_path = pod_path.join("task.socket");
    UnixListener::bind(&socket_path).expect("Failed to create socket");

    let resolved = resolve_pod_id(temp_dir.path().to_str().unwrap(), "pod-xyz");
    assert!(resolved.is_err());
    let error_msg = resolved.unwrap_err().to_string();
    assert!(error_msg.contains("No pod found with prefix"));
    assert!(error_msg.contains("pod-abc-123"));
}

#[test]
fn test_resolve_pod_id_empty_directory_error() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    let resolved = resolve_pod_id(temp_dir.path().to_str().unwrap(), "pod-123");
    assert!(resolved.is_err());
    let error_msg = resolved.unwrap_err().to_string();
    assert!(error_msg.contains("No pods found"));
}

#[test]
fn test_resolve_pod_id_single_character_prefix() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    // Create pods with different first characters
    let pod_ids = vec!["abc-123", "xyz-789"];
    for pod_id in &pod_ids {
        let pod_path = temp_dir.path().join(pod_id);
        fs::create_dir(&pod_path).expect("Failed to create pod dir");
        let socket_path = pod_path.join("task.socket");
        UnixListener::bind(&socket_path).expect("Failed to create socket");
    }

    let resolved = resolve_pod_id(temp_dir.path().to_str().unwrap(), "a");
    assert!(resolved.is_ok());
    assert_eq!(resolved.unwrap(), "abc-123");
}

#[test]
fn test_resolve_pod_id_numeric_prefix() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    // Create pods with numeric IDs
    let pod_ids = vec!["12345", "67890", "11111"];
    for pod_id in &pod_ids {
        let pod_path = temp_dir.path().join(pod_id);
        fs::create_dir(&pod_path).expect("Failed to create pod dir");
        let socket_path = pod_path.join("task.socket");
        UnixListener::bind(&socket_path).expect("Failed to create socket");
    }

    let resolved = resolve_pod_id(temp_dir.path().to_str().unwrap(), "1");
    assert!(resolved.is_err());
    let error_msg = resolved.unwrap_err().to_string();
    assert!(error_msg.contains("matches multiple pods"));

    let resolved = resolve_pod_id(temp_dir.path().to_str().unwrap(), "12");
    assert!(resolved.is_ok());
    assert_eq!(resolved.unwrap(), "12345");
}

#[test]
fn test_resolve_pod_id_case_sensitive() {
    let temp_dir = TempDir::new().expect("Failed to create temp dir");

    // Create pods with different cases
    let pod_ids = vec!["Pod-ABC", "pod-abc", "POD-abc"];
    for pod_id in &pod_ids {
        let pod_path = temp_dir.path().join(pod_id);
        fs::create_dir(&pod_path).expect("Failed to create pod dir");
        let socket_path = pod_path.join("task.socket");
        UnixListener::bind(&socket_path).expect("Failed to create socket");
    }

    let resolved = resolve_pod_id(temp_dir.path().to_str().unwrap(), "Pod");
    assert!(resolved.is_ok());
    assert_eq!(resolved.unwrap(), "Pod-ABC");

    let resolved = resolve_pod_id(temp_dir.path().to_str().unwrap(), "pod");
    assert!(resolved.is_ok());
    assert_eq!(resolved.unwrap(), "pod-abc");

    let resolved = resolve_pod_id(temp_dir.path().to_str().unwrap(), "POD");
    assert!(resolved.is_ok());
    assert_eq!(resolved.unwrap(), "POD-abc");
}
