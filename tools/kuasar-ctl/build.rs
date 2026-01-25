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

fn main() {
    // Get git commit information
    let commit_hash = std::process::Command::new("git")
        .args(["rev-parse", "HEAD"])
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .unwrap_or_else(|_| "unknown".to_string());

    let commit_date = std::process::Command::new("git")
        .args(["log", "-1", "--format=%cd", "--date=short"])
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .unwrap_or_else(|_| "unknown".to_string());

    let commit_message = std::process::Command::new("git")
        .args(["log", "-1", "--format=%s"])
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .unwrap_or_else(|_| "unknown".to_string());

    let short_hash = if commit_hash.len() >= 8 {
        &commit_hash[..8]
    } else {
        &commit_hash
    };

    // Set cargo build variables
    println!("cargo:rustc-env=KUASAR_CTL_COMMIT_HASH={}", commit_hash);
    println!("cargo:rustc-env=KUASAR_CTL_COMMIT_SHORT={}", short_hash);
    println!("cargo:rustc-env=KUASAR_CTL_COMMIT_DATE={}", commit_date);
    println!("cargo:rustc-env=KUASAR_CTL_COMMIT_MSG={}", commit_message);

    // Rebuild if git info changes
    println!("cargo:rerun-if-changed=.git/HEAD");
    println!("cargo:rerun-if-changed=.git/refs/heads/main");
}
