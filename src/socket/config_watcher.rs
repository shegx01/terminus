//! Config hot-reload watcher for socket client tokens.
//!
//! Watches `terminus.toml` for file-system changes and reloads the client
//! list when the file is modified. Only client tokens and names are reloaded;
//! bind address, port, and other structural config still require a restart.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::mpsc;

use crate::config::{Config, SocketClient};

/// Shared, atomically-swappable client list.
pub type SharedClientList = Arc<ArcSwap<Vec<SocketClient>>>;

/// Spawn a background task that watches `config_path` for changes and
/// reloads socket client entries into `shared_clients`.
///
/// Only `[[socket.client]]` entries are reloaded. Changes to bind, port,
/// max_connections, etc. are logged as warnings (require restart).
///
/// Watches the config FILE directly (not its parent directory) to avoid
/// the kqueue backend opening FDs for every sibling entry.  After an
/// editor atomic-save (rename), the kqueue watch is lost; we re-establish
/// it after each reload so subsequent edits are still detected.
pub fn spawn_config_watcher(
    config_path: PathBuf,
    shared_clients: SharedClientList,
) -> Option<tokio::task::JoinHandle<()>> {
    let (fs_tx, mut fs_rx) = mpsc::channel::<()>(4);

    let mut watcher = match RecommendedWatcher::new(
        move |res: Result<notify::Event, notify::Error>| {
            if let Ok(event) = res {
                // Any vnode event on the config file (modify, rename, delete)
                // triggers a reload attempt.
                let dominated =
                    event.kind.is_modify() || event.kind.is_create() || event.kind.is_remove();
                if dominated {
                    let _ = fs_tx.try_send(());
                }
            }
        },
        notify::Config::default(),
    ) {
        Ok(w) => w,
        Err(e) => {
            tracing::warn!(
                "Failed to create config file watcher: {} — hot-reload disabled",
                e
            );
            return None;
        }
    };

    // Watch the config file directly — avoids kqueue opening FDs for every
    // entry in the parent directory (which caused FD exhaustion when the
    // parent was the project root containing target/, .git/, etc.).
    if let Err(e) = watcher.watch(&config_path, RecursiveMode::NonRecursive) {
        tracing::warn!(
            "Failed to watch config file {}: {} — hot-reload disabled",
            config_path.display(),
            e
        );
        return None;
    }

    let handle = tokio::spawn(async move {
        // Watcher must stay alive; it is also mutated to re-watch after renames.
        let mut watcher = watcher;

        while fs_rx.recv().await.is_some() {
            // Debounce: sleep 500ms to collect rapid-fire events (editor
            // write + rename), then drain and reload the final state.
            // This prevents the old drain-then-process pattern that could
            // permanently swallow valid changes arriving during reload.
            tokio::time::sleep(Duration::from_millis(500)).await;

            // Drain any events that arrived during the sleep window
            while fs_rx.try_recv().is_ok() {}

            tracing::info!("Config file changed, attempting hot-reload of socket clients...");

            // Re-watch BEFORE reload so the new inode is tracked while we
            // parse.  Any edit arriving during reload queues another event
            // for the next iteration (absorbed by the debounce).
            if let Err(e) = watcher.unwatch(&config_path) {
                tracing::debug!(
                    "unwatch before re-watch returned error (expected after rename): {}",
                    e
                );
            }
            if let Err(e) = watcher.watch(&config_path, RecursiveMode::NonRecursive) {
                tracing::warn!(
                    "Failed to re-watch config file: {} — \
                     subsequent config changes may not be detected until restart",
                    e
                );
            }

            match Config::load(&config_path) {
                Ok(new_config) => {
                    let new_clients = new_config.socket.clients;
                    let old_clients = shared_clients.load();

                    // Log what changed
                    let old_names: std::collections::HashSet<&str> =
                        old_clients.iter().map(|c| c.name.as_str()).collect();
                    let new_names: std::collections::HashSet<&str> =
                        new_clients.iter().map(|c| c.name.as_str()).collect();

                    for name in new_names.difference(&old_names) {
                        tracing::info!("Config hot-reload: added client '{}'", name);
                    }
                    for name in old_names.difference(&new_names) {
                        tracing::info!("Config hot-reload: removed client '{}'", name);
                    }
                    for name in old_names.intersection(&new_names) {
                        let old_token = old_clients
                            .iter()
                            .find(|c| c.name == *name)
                            .map(|c| &c.token);
                        let new_token = new_clients
                            .iter()
                            .find(|c| c.name == *name)
                            .map(|c| &c.token);
                        if old_token != new_token {
                            tracing::info!(
                                "Config hot-reload: rotated token for client '{}'",
                                name
                            );
                        }
                    }

                    shared_clients.store(Arc::new(new_clients));
                    tracing::info!("Socket client list hot-reloaded successfully");
                }
                Err(e) => {
                    tracing::warn!("Config hot-reload failed (keeping old config): {}", e);
                }
            }
        }
    });

    Some(handle)
}
