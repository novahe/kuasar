use std::hash::{Hash, Hasher};
use std::collections::hash_map::DefaultHasher;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::anyhow;
use lazy_static::lazy_static;
use opentelemetry::trace::{SpanContext, TraceContextExt, TraceFlags, TraceState};
use opentelemetry::{
    global,
    sdk::{
        trace::{self, Tracer},
        Resource,
    },
};
use tracing::Span;
use tracing_opentelemetry::OpenTelemetrySpanExt;
use tracing_subscriber::{
    layer::SubscriberExt, util::SubscriberInitExt, EnvFilter, Layer, Registry,
};
use opentelemetry_otlp::WithExportConfig;

lazy_static! {
    static ref TRACE_ENABLED: AtomicBool = AtomicBool::new(false);
    static ref SANDBOX_ID: std::sync::RwLock<Option<String>> = std::sync::RwLock::new(None);
}

pub fn is_enabled() -> bool {
    TRACE_ENABLED.load(Ordering::Relaxed)
}

pub fn set_enabled(enabled: bool) {
    TRACE_ENABLED.store(enabled, Ordering::Relaxed);
}

pub fn set_sandbox_id(id: &str) {
    if let Ok(mut guard) = SANDBOX_ID.write() {
        *guard = Some(id.to_string());
    }
}

pub fn get_sandbox_id() -> Option<String> {
    SANDBOX_ID.read().ok().and_then(|guard| guard.clone())
}

pub fn setup_tracing(log_level: &str, otlp_service_name: &str) -> anyhow::Result<()> {
    let env_filter = init_logger_filter(log_level)
        .map_err(|e| anyhow!("failed to init logger filter: {}", e))?;

    let mut layers = vec![tracing_subscriber::fmt::layer().boxed()];
    // TODO: shutdown tracer provider when is_enabled is false
    if is_enabled() {
        let tracer = init_otlp_tracer(otlp_service_name)
            .map_err(|e| anyhow!("failed to init otlp tracer: {}", e))?;
        layers.push(tracing_opentelemetry::layer().with_tracer(tracer).boxed());
    }

    Registry::default()
        .with(env_filter)
        .with(layers)
        .try_init()?;
    Ok(())
}

fn init_logger_filter(log_level: &str) -> anyhow::Result<EnvFilter> {
    let filter = EnvFilter::from_default_env()
        .add_directive(format!("containerd_sandbox={}", log_level).parse()?)
        .add_directive(format!("vmm_sandboxer={}", log_level).parse()?);
    Ok(filter)
}

pub fn init_otlp_tracer(otlp_service_name: &str) -> anyhow::Result<Tracer> {
    // Support OTEL_EXPORTER_OTLP_ENDPOINT and OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
    // Default: http://localhost:4317 (OTLP gRPC)
    let endpoint = std::env::var("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")
        .or_else(|_| std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT"))
        .unwrap_or_else(|_| "http://localhost:4317".to_string());

    log::info!("Initializing OTLP tracer with endpoint: {}", endpoint);

    let tracer = opentelemetry_otlp::new_pipeline()
        .tracing()
        .with_exporter(
            opentelemetry_otlp::new_exporter()
                .tonic()
                .with_endpoint(endpoint)
        )
        .with_trace_config(trace::config().with_resource(Resource::new(vec![
            opentelemetry::KeyValue::new("service.name", otlp_service_name.to_string()),
        ])))
        .install_batch(opentelemetry::runtime::Tokio)?;
    Ok(tracer)
}

// TODO: may hang indefinitely, use it again when https://github.com/open-telemetry/opentelemetry-rust/issues/868 is resolved
#[allow(dead_code)]
pub fn shutdown_tracing() {
    global::shutdown_tracer_provider();
}

pub fn sandbox_id_to_trace_id(sandbox_id: &str) -> [u8; 16] {
    let mut hasher_low = DefaultHasher::new();
    sandbox_id.hash(&mut hasher_low);
    let low = hasher_low.finish();

    let mut hasher_high = DefaultHasher::new();
    // Use a fixed salt to generate distinct bits for the high 64 bits
    "kuasar-trace-salt".hash(&mut hasher_high);
    sandbox_id.hash(&mut hasher_high);
    let high = hasher_high.finish();

    let mut trace_id = [0u8; 16];
    trace_id[..8].copy_from_slice(&low.to_le_bytes());
    trace_id[8..].copy_from_slice(&high.to_le_bytes());
    trace_id
}

pub fn create_trace_span(name: &str, sandbox_id: &str) -> Span {
    let trace_id = opentelemetry::trace::TraceId::from_bytes(sandbox_id_to_trace_id(sandbox_id));
    let span = tracing::info_span!(target: "kuasar_trace", "dynamic_span", name = name);
    
    // Create a SpanContext with the deterministic TraceId and a default SpanId.
    // Setting SpanId to all zeros (invalid) might cause issues, but usually OTel 
    // will generate a random SpanId if we don't provide one, while keeping the TraceId.
    // However, the cleanest way to "seed" the TraceId for a new root span is to
    // set a remote parent with that TraceId.
    
    let span_context = SpanContext::new(
        trace_id,
        opentelemetry::trace::SpanId::INVALID,
        TraceFlags::default(),
        true, // is_remote
        TraceState::default(),
    );
    
    span.set_parent(opentelemetry::Context::new().with_remote_span_context(span_context));
    span
}


pub fn sandbox_id_to_context(sandbox_id: &str) -> opentelemetry::Context {
    let trace_id = opentelemetry::trace::TraceId::from_bytes(sandbox_id_to_trace_id(sandbox_id));
    let span_context = SpanContext::new(
        trace_id,
        opentelemetry::trace::SpanId::INVALID,
        TraceFlags::default(),
        true, // is_remote
        TraceState::default(),
    );
    opentelemetry::Context::new().with_remote_span_context(span_context)
}
