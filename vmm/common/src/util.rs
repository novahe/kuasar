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

use std::time::Instant;

pub struct NovaTracer {
    op_name: &'static str,
    sandbox_id: Option<String>,
    start: Instant,
}

impl NovaTracer {
    pub fn new(op_name: &'static str, sandbox_id: Option<String>) -> Self {
        Self {
            op_name,
            sandbox_id,
            start: Instant::now(),
        }
    }
}

impl Drop for NovaTracer {
    fn drop(&mut self) {
        let elapsed = self.start.elapsed();
        if let Some(ref id) = self.sandbox_id {
            // Output format: ... nova: sandboxer create_vm <ID> took 15.2ms
            log::info!("nova: {} {} took {:?}", self.op_name, id, elapsed);
        } else {
            // Output format: ... nova: task init_vm_rootfs mount core fs took 2.1ms
            log::info!("nova: {} took {:?}", self.op_name, elapsed);
        }
    }
}

// Convenient macro for usage
#[macro_export]
macro_rules! nova_trace {
    ($op:expr) => {
        let _guard = $crate::util::NovaTracer::new($op, None);
    };
    ($op:expr, $id:expr) => {
        let _guard = $crate::util::NovaTracer::new($op, Some($id.to_string()));
    };
}
