/*
Copyright 2024 The Kuasar Authors.

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

use std::{collections::HashMap, sync::atomic::{AtomicBool, Ordering}};

use anyhow::anyhow;
use lazy_static::lazy_static;
use opentelemetry::{
    global,
    propagation::{Extractor, Injector, TextMapPropagator},
    sdk::{
        propagation::TraceContextPropagator,
        trace::{self, Tracer},
        Resource,
    },
};
use tracing::Span;
use tracing_opentelemetry::OpenTelemetrySpanExt;
use tracing_subscriber::{
    layer::SubscriberExt, util::SubscriberInitExt, EnvFilter, Layer, Registry,
};

lazy_static! {
    static ref TRACE_ENABLED: AtomicBool = AtomicBool::new(false);
}

pub fn is_enabled() -> bool {
    TRACE_ENABLED.load(Ordering::Relaxed)
}

pub fn set_enabled(enabled: bool) {
    TRACE_ENABLED.store(enabled, Ordering::Relaxed);
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
    let tracer = opentelemetry_otlp::new_pipeline()
        .tracing()
        .with_exporter(opentelemetry_otlp::new_exporter().tonic())
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

/// TtrpcMetadataCarrier implements OpenTelemetry Injector/Extractor traits
/// for ttrpc metadata to enable W3C Trace Context propagation across ttrpc boundaries.
pub struct TtrpcMetadataCarrier<'a> {
    metadata: &'a mut HashMap<String, Vec<String>>,
}

impl<'a> TtrpcMetadataCarrier<'a> {
    pub fn new(metadata: &'a mut HashMap<String, Vec<String>>) -> Self {
        Self { metadata }
    }
}

impl<'a> Injector for TtrpcMetadataCarrier<'a> {
    fn set(&mut self, key: &str, value: String) {
        self.metadata.insert(key.to_string(), vec![value]);
    }
}

impl<'a> Extractor for TtrpcMetadataCarrier<'a> {
    fn get(&self, key: &str) -> Option<&str> {
        self.metadata
            .get(key)
            .and_then(|v| v.first())
            .map(|s| s.as_str())
    }

    fn keys(&self) -> Vec<&str> {
        self.metadata.keys().map(|k| k.as_str()).collect()
    }
}

/// Inject current trace context into ttrpc metadata.
/// Returns early if tracing is disabled (zero overhead).
pub fn inject_trace_context(metadata: &mut HashMap<String, Vec<String>>) {
    if !is_enabled() {
        return;
    }

    let propagator = TraceContextPropagator::new();
    let context = Span::current().context();
    let mut carrier = TtrpcMetadataCarrier::new(metadata);
    propagator.inject_context(&context, &mut carrier);
}

/// Extract trace context from ttrpc metadata and set as parent of current span.
/// Returns None if no trace context found (graceful degradation).
pub fn extract_trace_context(
    metadata: Option<&HashMap<String, Vec<String>>>,
) -> Option<opentelemetry::Context> {
    if !is_enabled() {
        return None;
    }

    let metadata = metadata?;
    let propagator = TraceContextPropagator::new();
    let mut carrier_map = metadata.clone();
    let carrier = TtrpcMetadataCarrier::new(&mut carrier_map);
    let context = propagator.extract(&carrier);

    Some(context)
}
