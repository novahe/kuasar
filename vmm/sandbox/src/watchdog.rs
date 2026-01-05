use std::env;
use std::time::Duration;
use tokio::time;
use log::{info, warn, debug};

pub async fn run_watchdog() {
    // Check if WATCHDOG_USEC is set
    let watchdog_usec = match env::var("WATCHDOG_USEC") {
        Ok(val) => val,
        Err(_) => {
            debug!("WATCHDOG_USEC not set, skipping watchdog");
            return;
        }
    };

    let usec: u64 = match watchdog_usec.parse() {
        Ok(val) => val,
        Err(e) => {
            warn!("Failed to parse WATCHDOG_USEC: {}, skipping watchdog", e);
            return;
        }
    };

    // Calculate interval (usually half of the timeout)
    let interval_ms = usec / 1000 / 2;
    let mut interval = time::interval(Duration::from_millis(interval_ms));

    info!("Starting systemd watchdog with interval {} ms", interval_ms);

    // Notify ready
    if let Err(e) = sd_notify::notify(false, &[sd_notify::NotifyState::Ready]) {
         warn!("Failed to notify systemd READY: {}", e);
    }

    loop {
        interval.tick().await;
        debug!("Sending watchdog notification");
        if let Err(e) = sd_notify::notify(false, &[sd_notify::NotifyState::Watchdog]) {
            warn!("Failed to notify systemd WATCHDOG: {}", e);
        }
    }
}
