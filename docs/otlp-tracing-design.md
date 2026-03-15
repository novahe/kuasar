# OTLP Tracing Implementation for Kuasar Pod Creation Chain

## Overview

This document describes the implementation of distributed tracing using OpenTelemetry Protocol (OTLP) for the kuasar sandboxer → Cloud Hypervisor guest task chain for pod creation.

## Motivation

### Why This Change is Needed

- Currently, kuasar has basic OTLP infrastructure but no trace context propagation between services
- Debugging pod creation issues requires correlating logs across host sandboxer and guest task services
- No visibility into the complete request flow from sandboxer through to the guest VM
- **User requirement**: containerd's trace ID needs to be propagated through kuasar (will be received from shim layer)

### Current State

- VMM components have OpenTelemetry dependencies (tracing 0.1.40, opentelemetry-otlp 0.13.0)
- Basic tracer initialization exists in `vmm/common/src/trace.rs`
- Very limited instrumentation (only 3 `#[instrument]` attributes)
- **Critical gap**: No W3C Trace Context propagation across ttrpc boundaries

## Architecture

### Component Flow

```
containerd (external, has trace ID)
    ↓ ttrpc call
kuasar-shim (external, not in this repo - will pass trace context)
    ↓ ttrpc call via Unix socket (/run/vmm-sandboxer.sock)
    ↓ [trace context in ttrpc metadata]
vmm-sandboxer (host process) ← THIS REPO
    ↓ ttrpc call via vsock (port 1024)
    ↓ [trace context in ttrpc metadata]
vmm-task (guest VM process) ← THIS REPO
```

### Scope

This implementation focuses on the kuasar repository only:
- **vmm/common/** - Shared trace context propagation utilities
- **vmm/sandbox/** - Sandboxer layer (receives trace context from shim, propagates to guest)
- **vmm/task/** - Guest task layer (receives trace context from sandboxer)

**Note**: The shim layer (containerd-shim-kuasar-vmm-v2) is external to this repository. This plan assumes the shim will pass trace context via ttrpc metadata.

## Implementation Details

### Phase 1: Core Trace Context Propagation Infrastructure

**File: `vmm/common/src/trace.rs`**

Added W3C Trace Context propagation utilities:

1. **TtrpcMetadataCarrier struct**
   - Implements OpenTelemetry `Injector`/`Extractor` traits
   - Wraps `HashMap<String, Vec<String>>` for ttrpc metadata
   - Provides `set()` and `get()` methods for trace context headers

2. **inject_trace_context() function**
   - Extracts current span context
   - Injects traceparent/tracestate into ttrpc metadata
   - Returns early if tracing disabled (zero overhead)
   - Usage: Call before every ttrpc client request

3. **extract_trace_context() function**
   - Extracts traceparent/tracestate from incoming ttrpc metadata
   - Creates parent span context
   - Returns None if no context found (graceful degradation)
   - Usage: Call at start of every ttrpc service handler

**Key design decisions:**
- Use ttrpc metadata (not proto changes) for backward compatibility
- W3C Trace Context format for interoperability
- Early returns when `trace::is_enabled()` is false

### Phase 2: Sandboxer Layer Instrumentation

**File: `vmm/sandbox/src/sandbox.rs`**

Add trace context extraction and instrumentation to key lifecycle methods:

1. **KuasarSandboxer::create()** - Extract trace context from shim and create root span
   - Extract trace context from incoming ttrpc request metadata (passed from shim)
   - If trace context exists, set as parent; otherwise start new trace
   - `#[instrument(skip_all, fields(sandbox_id = %id))]`
   - This continues the distributed trace from containerd/shim

2. **KuasarSandboxer::start()** - VM startup span (already has `#[instrument]`)
   - Verify instrumentation is working correctly

3. **KuasarSandbox::init_client()** - Guest connection span
   - `#[instrument(skip(self))]`
   - Records vsock connection establishment

4. **setup_sandbox()** - Guest configuration span
   - `#[instrument(skip_all)]`
   - Includes network setup, hostname, DNS config

5. **prepare_network()** - Network setup span
   - `#[instrument(skip_all)]`
   - TAP device creation, namespace setup

**File: `vmm/sandbox/src/client.rs`**

Inject trace context before ttrpc calls:

1. **client_setup_sandbox()** - Before calling `setup_sandbox` RPC
   - Create metadata HashMap
   - Call `inject_trace_context(&mut metadata)`
   - Pass metadata to ttrpc context

2. **client_check()** - Before calling `check` RPC
   - Same pattern as above

3. **client_sync_clock()** - Before calling `sync_clock` RPC
   - Same pattern as above

**Implementation pattern:**
```rust
let mut metadata = HashMap::new();
inject_trace_context(&mut metadata);
let ctx = ttrpc::context::with_timeout(timeout)
    .with_metadata(metadata);
client.method(ctx, &request)?
```

### Phase 3: Guest Task Layer Instrumentation

**File: `vmm/task/src/sandbox_service.rs`**

Extract trace context and instrument service handlers:

1. **SandboxService::check()** - Health check span
   - Extract trace context from `ctx.metadata`
   - Create child span with extracted parent
   - `#[instrument(skip_all)]`

2. **SandboxService::setup_sandbox()** - Sandbox setup span
   - Extract trace context
   - Instrument network interface and route configuration
   - `#[instrument(skip_all, fields(interfaces_count, routes_count))]`

3. **SandboxService::update_interfaces()** - Network interface span
   - Extract trace context
   - `#[instrument(skip_all, fields(count = req.interfaces.len()))]`

4. **SandboxService::update_routes()** - Network routing span
   - Extract trace context
   - `#[instrument(skip_all, fields(count = req.routes.len()))]`

**Implementation pattern:**
```rust
async fn method(&self, ctx: &TtrpcContext, req: &Request) -> TtrpcResult<Response> {
    let parent_cx = extract_trace_context(ctx.metadata.as_ref());
    let span = tracing::info_span!("method_name");

    if let Some(parent) = parent_cx {
        span.set_parent(parent);
    }

    let _guard = span.enter();
    // method implementation
}
```

**File: `vmm/task/src/main.rs`**

Add instrumentation to task service initialization:

1. **main()** - Task service startup span
   - `#[instrument]`
   - Records service initialization

2. **Server registration** - Ensure ttrpc server preserves metadata
   - Verify ttrpc context is passed to handlers

### Phase 4: Cloud Hypervisor Specific Instrumentation

**File: `vmm/sandbox/src/cloud_hypervisor/mod.rs`**

Already has `#[instrument(skip_all)]` on VM trait methods. Verify these are working:
- `start()` - VM process launch
- `stop()` - VM shutdown
- `hot_attach()` - Device hot-plug
- `recover()` - VM recovery after restart

**File: `vmm/sandbox/src/cloud_hypervisor/factory.rs`**

Add instrumentation to VM creation:

1. **CloudHypervisorVMFactory::create_vm()** - VM construction span
   - `#[instrument(skip_all, fields(vm_id = %id))]`
   - Records device setup (pmem, vsock, virtiofs, network)

### Phase 5: Configuration and Dependencies

**File: `vmm/common/Cargo.toml`**

Dependencies updated to latest versions:
```toml
tracing = "0.1.40"
tracing-opentelemetry = "0.32.1"
opentelemetry = { version = "0.31.0", features = ["rt-tokio"] }
opentelemetry-otlp = "0.31.0"
```

**Note**: These versions are compatible with Rust 1.85 (project's minimum supported version).

**File: `vmm/sandbox/src/bin/cloud_hypervisor/main.rs`**

Ensure tracing is initialized with correct service name:
```rust
trace::setup_tracing(&log_level, "kuasar-vmm-sandboxer-clh-service")?;
```

**File: `vmm/task/src/main.rs`**

Ensure tracing is initialized with correct service name:
```rust
trace::setup_tracing(&log_level, "kuasar-vmm-task-service")?;
```

## Trace Hierarchy

### Pod Creation Flow

```
[containerd trace - external]
    ↓ trace context via ttrpc metadata from shim
create_sandbox [sandboxer - continues containerd trace]
├─ create_vm [sandboxer]
│  ├─ setup_devices [sandboxer]
│  └─ configure_network [sandboxer]
├─ start_sandbox [sandboxer]
│  ├─ start_vm [sandboxer]
│  ├─ init_client [sandboxer]
│  ├─ check [guest] ← trace context propagated via ttrpc metadata
│  ├─ setup_sandbox [guest] ← trace context propagated via ttrpc metadata
│  │  ├─ update_interfaces [guest]
│  │  └─ update_routes [guest]
│  └─ add_to_cgroup [sandboxer]
└─ monitor_vm [sandboxer]
```

### Container Creation Flow

**Important**: Container creation bypasses the sandboxer layer. Containerd directly calls vmm-task's task service interface.

```
[containerd trace - external]
    ↓ trace context via ttrpc metadata (direct call to guest)
create_container [guest task service] ← trace context from containerd
├─ create [guest task service]
│  ├─ setup_bundle [guest]
│  ├─ setup_rootfs [guest]
│  ├─ setup_mounts [guest]
│  └─ create_process [guest]
└─ start_container [guest task service]
   ├─ start [guest task service]
   ├─ setup_io [guest]
   └─ exec_process [guest]
```

**Key points:**
- Sandboxer receives trace context from shim via ttrpc metadata (containerd's trace ID)
- Sandboxer continues the trace (not starting a new root span)
- Sandboxer propagates trace context to guest via ttrpc metadata for pod setup
- **Container operations**: containerd → vmm-task directly (no sandboxer involvement)
- Complete trace spans from containerd → shim → sandboxer → guest (pod) and containerd → guest (container)

## Testing and Verification

### Local Testing Setup

1. **Start OTLP Collector (Jaeger)**
```bash
docker run -d --name jaeger \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 16686:16686 \
  -p 4317:4317 \
  jaegertracing/all-in-one:latest
```

2. **Configure Environment**
```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
```

3. **Enable Tracing in Config**
```toml
# vmm-sandboxer config
enable_tracing = true
log_level = "debug"
```

```bash
# Guest kernel cmdline
task.enable_tracing=true task.log_level=debug
```

4. **Create Test Pod**
```bash
crictl run container.json pod.json
```

5. **Verify in Jaeger UI**
- Open http://localhost:16686
- Search for service "kuasar-vmm-sandboxer-clh-service"
- Verify trace spans from sandboxer → guest
- Check parent-child relationships

### Test Cases

1. **Happy Path** - Complete pod creation with tracing enabled
   - Verify all spans present
   - Verify parent-child relationships
   - Verify trace context propagation

2. **Tracing Disabled** - Pod creation with `enable_tracing=false`
   - Verify no performance impact
   - Verify no errors

3. **Missing Trace Context** - Guest receives request without trace context
   - Verify graceful degradation
   - Verify new trace starts

4. **Concurrent Requests** - Multiple pods created simultaneously
   - Verify traces don't interfere
   - Verify correct span isolation

5. **Error Scenarios** - VM startup failure, network setup failure
   - Verify error spans recorded
   - Verify trace completes even on error

## Performance Considerations

- **Overhead when enabled**: ~1-5μs per span, ~100-500ns per RPC metadata injection
- **Overhead when disabled**: Near-zero (early returns in inject/extract functions)
- **Batched export**: OTLP uses async batching, minimal impact on critical path
- **Memory**: ~1KB per trace, auto-pruned after export

## Backwards Compatibility

✅ No proto message changes (uses ttrpc metadata)
✅ Optional via config flag (enable_tracing)
✅ Graceful degradation when trace context missing
✅ No breaking changes to existing APIs

## Risks and Mitigations

**Risk**: ttrpc metadata not preserved across calls
- **Mitigation**: Test with actual ttrpc library, verify metadata passing

**Risk**: Performance impact on critical path
- **Mitigation**: Early returns when tracing disabled, async export

**Risk**: Trace context lost at shim boundary
- **Mitigation**: Document shim requirements, provide example implementation

**Risk**: Version compatibility with OpenTelemetry
- **Mitigation**: Use stable W3C Trace Context format, not library-specific

## Shim Layer Requirements (External to This Repo)

For complete end-to-end tracing from containerd, the shim layer (containerd-shim-kuasar-vmm-v2) needs to:

1. **Extract trace context from containerd** - Read traceparent/tracestate from containerd's request
2. **Inject into ttrpc metadata** - When calling sandboxer, add trace context to ttrpc metadata
3. **Example pattern**:
```rust
let mut metadata = HashMap::new();
metadata.insert("traceparent".to_string(), vec![traceparent_value]);
metadata.insert("tracestate".to_string(), vec![tracestate_value]);
let ctx = ttrpc::context::with_timeout(timeout).with_metadata(metadata);
```

This implementation in kuasar is designed to accept trace context from the shim layer via ttrpc metadata.

## Future Enhancements

1. **Metrics** - Add OpenTelemetry metrics for pod creation latency
2. **Logs Correlation** - Link logs to traces via trace_id
3. **Sampling** - Add configurable sampling for high-volume environments
4. **Baggage** - Propagate additional context (pod name, namespace, etc.)
5. **Span Events** - Add events for key milestones (VM started, network ready, etc.)

## Implementation Status

### Completed
- ✅ Phase 1: Core trace context propagation infrastructure in `vmm/common/src/trace.rs`

### In Progress
- 🔄 Phase 2: Sandboxer layer instrumentation
- 🔄 Phase 3: Guest task layer instrumentation
- 🔄 Phase 4: Cloud Hypervisor specific instrumentation
- 🔄 Phase 5: Configuration verification

### Pending
- ⏳ Testing and verification
- ⏳ Documentation updates
- ⏳ Shim layer coordination

## References

- [OpenTelemetry Specification](https://opentelemetry.io/docs/specs/otel/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [ttrpc Protocol](https://github.com/containerd/ttrpc)
- [Kuasar Architecture](../README.md)
