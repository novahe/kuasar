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

use thiserror::Error;

pub type Result<T> = std::result::Result<T, KuasarCtlError>;

#[derive(Error, Debug)]
pub enum KuasarCtlError {
    #[error("sandbox '{0}' not found")]
    SandboxNotFound(String),

    #[error("vsock connection failed: {0}")]
    VsockConnectionFailed(#[from] anyhow::Error),

    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("write output file failed: {0}")]
    WriteOutputFailed(#[from] std::fmt::Error),

    #[error("epoll error: {0}")]
    EpollError(String),
}

// Implement From for interactive::Error
impl From<crate::interactive::Error> for KuasarCtlError {
    fn from(err: crate::interactive::Error) -> Self {
        KuasarCtlError::EpollError(err.to_string())
    }
}

impl KuasarCtlError {
    pub fn exit_code(&self) -> i32 {
        match self {
            KuasarCtlError::SandboxNotFound(_) => 1,
            KuasarCtlError::VsockConnectionFailed(_) => 3,
            KuasarCtlError::IoError(_) => 126,
            KuasarCtlError::WriteOutputFailed(_) => 127,
            KuasarCtlError::EpollError(_) => 128,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io;

    #[test]
    fn test_sandbox_not_found_error() {
        let err = KuasarCtlError::SandboxNotFound("test-pod".to_string());
        assert_eq!(err.exit_code(), 1);
        assert_eq!(err.to_string(), "sandbox 'test-pod' not found");
    }

    #[test]
    fn test_vsock_connection_failed_error() {
        let anyhow_err = anyhow::anyhow!("connection failed");
        let err = KuasarCtlError::VsockConnectionFailed(anyhow_err);
        assert_eq!(err.exit_code(), 3);
        assert!(err.to_string().contains("vsock connection failed"));
    }

    #[test]
    fn test_io_error() {
        let io_err = io::Error::new(io::ErrorKind::NotFound, "file not found");
        let err = KuasarCtlError::IoError(io_err);
        assert_eq!(err.exit_code(), 126);
        assert!(err.to_string().contains("IO error"));
    }

    #[test]
    fn test_write_output_failed_error() {
        let fmt_err = std::fmt::Error {};
        let err = KuasarCtlError::WriteOutputFailed(fmt_err);
        assert_eq!(err.exit_code(), 127);
        assert!(err.to_string().contains("write output file failed"));
    }

    #[test]
    fn test_result_type_alias() {
        // Test that Result works as expected
        fn returns_ok() -> Result<String> {
            Ok("success".to_string())
        }

        fn returns_err() -> Result<String> {
            Err(KuasarCtlError::SandboxNotFound("test".to_string()))
        }

        assert!(returns_ok().is_ok());
        assert_eq!(returns_ok().unwrap(), "success");
        assert!(returns_err().is_err());
        assert_eq!(returns_err().unwrap_err().exit_code(), 1);
    }

    #[test]
    fn test_error_display_formats() {
        // Test that error messages are user-friendly
        let errors = vec![
            KuasarCtlError::SandboxNotFound("pod-123".to_string()),
        ];

        for err in errors {
            let msg = err.to_string();
            assert!(!msg.is_empty(), "error message should not be empty");
        }
    }
}
