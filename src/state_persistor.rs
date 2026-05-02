//! `StatePersistor` — owns the on-disk `StateStore` and the debounce policy
//! that throttles `persist()` calls.
//!
//! Extracted from `App` so the debounce-or-force-persist state machine
//! (≥10 updates OR ≥5s elapsed, with safety-critical variants bypassing the
//! window) can be unit-tested end-to-end without standing up a full `App`.
//!
//! ## Ownership
//! - `store`: the only writer; adapters publish `StateUpdate`s through an
//!   mpsc channel that `App` drains and forwards via [`StatePersistor::apply`].
//! - `last_persist`, `updates_since_persist`: debounce counters.
//! - `dirty_sent`: one-shot guard that lets `handle_command` send a single
//!   `MarkDirty` on the first user interaction (claimed via
//!   [`StatePersistor::claim_dirty_send`]).

use std::time::{Duration, Instant};

use anyhow::Result;

use crate::state_store::{State, StateStore, StateUpdate};

/// Persists `StateStore` writes with a debounce window, force-persisting
/// safety-critical variants. Owned by `App`.
pub struct StatePersistor {
    store: StateStore,
    last_persist: Instant,
    updates_since_persist: u32,
    dirty_sent: bool,
}

impl StatePersistor {
    /// Wrap a loaded `StateStore`. Does NOT apply the startup `MarkDirty`
    /// marker — callers should snapshot first (to capture the previous run's
    /// `last_clean_shutdown`) and then call [`Self::apply_force`] with
    /// `MarkDirty` so a crash within the first ~5s still leaves the dirty
    /// flag on disk.
    pub fn new(store: StateStore) -> Self {
        Self {
            store,
            last_persist: Instant::now(),
            updates_since_persist: 0,
            dirty_sent: false,
        }
    }

    /// Borrow the in-memory state snapshot.
    pub fn snapshot(&self) -> &State {
        self.store.snapshot()
    }

    /// Apply a `StateUpdate` to in-memory state and debounce persists.
    ///
    /// Persists when:
    /// - the variant is in the force-persist set (safety-critical), OR
    /// - ≥10 updates have accumulated since the last persist, OR
    /// - ≥5s have elapsed since the last persist.
    ///
    /// Persistence errors are logged but not propagated — the alternative
    /// (returning `Result` from this hot path) would require the caller to
    /// handle errors at every `state_rx` consumer, and there is no
    /// meaningful recovery beyond the log.
    pub fn apply(&mut self, update: StateUpdate) {
        let force = is_force_persist(&update);
        self.store.apply(update);
        self.updates_since_persist += 1;
        if force
            || self.updates_since_persist >= 10
            || self.last_persist.elapsed() >= Duration::from_secs(5)
        {
            if let Err(e) = self.store.persist() {
                tracing::error!("Failed to persist state: {}", e);
            }
            self.last_persist = Instant::now();
            self.updates_since_persist = 0;
        }
    }

    /// Apply an update and force-persist regardless of debounce state,
    /// propagating persistence errors to the caller. Used at startup so a
    /// failed initial persist fails `App::new` (rather than silently logging).
    pub fn apply_force(&mut self, update: StateUpdate) -> Result<()> {
        self.store.apply(update);
        self.store.persist()?;
        self.last_persist = Instant::now();
        self.updates_since_persist = 0;
        Ok(())
    }

    /// Mark `last_clean_shutdown = true` and force-persist. Called on
    /// graceful ctrl-c. Errors are logged (a graceful shutdown can't fail
    /// loud and the next boot will treat a missing dirty flag as clean,
    /// which is the correct fallback).
    pub fn mark_clean_shutdown(&mut self) {
        self.store.apply(StateUpdate::SetCleanShutdown(true));
        if let Err(e) = self.store.persist() {
            tracing::error!("Failed to persist clean-shutdown state: {}", e);
        } else {
            tracing::info!("Clean shutdown persisted");
        }
        self.last_persist = Instant::now();
        self.updates_since_persist = 0;
    }

    /// Returns `true` exactly once per persistor lifetime: on the first
    /// call. Used by `handle_command` to send a single `MarkDirty` on the
    /// first user interaction without sending duplicates on subsequent
    /// commands.
    ///
    /// The flag flips unconditionally when this returns `true`; the caller
    /// is responsible for the actual send. If the caller's `try_send` then
    /// fails (e.g. channel full), the dropped `MarkDirty` is acceptable —
    /// the startup `apply_force(MarkDirty)` already wrote the dirty bit to
    /// disk, so a missed first-interaction re-send does not weaken the
    /// restart-banner gate. Setting the flag pre-send avoids `MarkDirty`
    /// storms if the channel recovers between commands.
    pub fn claim_dirty_send(&mut self) -> bool {
        if self.dirty_sent {
            false
        } else {
            self.dirty_sent = true;
            true
        }
    }

    /// Test-only accessor for the debounce counter.
    #[cfg(test)]
    pub fn updates_since_persist(&self) -> u32 {
        self.updates_since_persist
    }

    /// Test-only setter for `last_persist` so the 5s elapsed-time debounce
    /// branch is exercisable without `tokio::time::pause` (which only
    /// affects `tokio::time::Instant`, not the `std::time::Instant` used
    /// here on the hot path).
    #[cfg(test)]
    pub fn set_last_persist_for_test(&mut self, instant: Instant) {
        self.last_persist = instant;
    }
}

/// Variants that bypass the debounce window. `MarkDirty` and
/// `SetCleanShutdown` underpin the restart-banner gate; `HarnessSessionBatch`
/// is what makes `--resume foo` survive a process restart; the watermark
/// variants are what makes wake-recovery lossless. A debounce-window crash
/// for any of these is a user-visible bug.
fn is_force_persist(update: &StateUpdate) -> bool {
    matches!(
        update,
        StateUpdate::MarkDirty
            | StateUpdate::SetCleanShutdown(_)
            | StateUpdate::HarnessSessionBatch(_)
            | StateUpdate::SlackWatermark { .. }
            | StateUpdate::DiscordWatermark { .. }
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state_store::NamedSessionEntry;
    use std::path::PathBuf;
    use tempfile::tempdir;

    fn fresh_persistor(dir: &std::path::Path) -> StatePersistor {
        let path = dir.join("terminus-state.json");
        let store = StateStore::load(&path).expect("load state");
        StatePersistor::new(store)
    }

    #[test]
    fn apply_debounces_below_threshold() {
        let dir = tempdir().unwrap();
        let mut p = fresh_persistor(dir.path());

        // Five non-force updates — below the 10-update threshold and well
        // under the 5s elapsed bound.
        for i in 0..5i64 {
            p.apply(StateUpdate::TelegramOffset(i));
        }
        assert_eq!(
            p.updates_since_persist(),
            5,
            "counter should accumulate without persisting"
        );
        assert!(
            !dir.path().join("terminus-state.json").exists(),
            "no persist should have hit disk yet"
        );
    }

    #[test]
    fn apply_persists_at_count_threshold() {
        let dir = tempdir().unwrap();
        let mut p = fresh_persistor(dir.path());

        for i in 0..10i64 {
            p.apply(StateUpdate::TelegramOffset(i));
        }
        assert_eq!(
            p.updates_since_persist(),
            0,
            "counter resets after a persist"
        );
        assert!(dir.path().join("terminus-state.json").exists());
    }

    #[test]
    fn apply_force_persist_variants_bypass_debounce() {
        // Every variant in `is_force_persist` must reset the counter on a
        // single apply(), proving the force path bypasses the 10-update /
        // 5-second debounce window. Without this, a crash before the next
        // window fires would drop a safety-critical update — the very
        // invariant the Bug 3 fix and the slack/discord watermark
        // force-persists were introduced to protect.
        let entry = NamedSessionEntry {
            session_id: "sid-1".into(),
            cwd: PathBuf::from("/tmp"),
            last_used: chrono::Utc::now(),
        };
        let force_variants: Vec<StateUpdate> = vec![
            StateUpdate::MarkDirty,
            StateUpdate::SetCleanShutdown(true),
            StateUpdate::HarnessSessionBatch(vec![("auth".into(), Some(entry))]),
            StateUpdate::SlackWatermark {
                channel_id: "C1".into(),
                ts: "1700000000.000001".into(),
            },
            StateUpdate::DiscordWatermark {
                channel_id: "D1".into(),
                message_id: 1_700_000_000_000_000_001,
            },
        ];

        for variant in force_variants {
            let dir = tempdir().unwrap();
            let mut p = fresh_persistor(dir.path());
            p.apply(variant);
            assert_eq!(
                p.updates_since_persist(),
                0,
                "force-persist variant must reset the counter"
            );
            assert!(
                dir.path().join("terminus-state.json").exists(),
                "force-persist variant must hit disk on a single apply"
            );
        }
    }

    #[test]
    fn apply_persists_after_5s_elapsed_with_one_update() {
        // The elapsed-time branch (`last_persist.elapsed() >= 5s`) is a
        // distinct trigger from the count threshold. Drift `last_persist`
        // back to simulate a quiet period, then a single non-force update
        // should persist immediately.
        let dir = tempdir().unwrap();
        let mut p = fresh_persistor(dir.path());

        // Push the recorded "last persist" instant six seconds into the
        // past — within the next apply() the elapsed check will fire.
        let stale = Instant::now() - Duration::from_secs(6);
        p.set_last_persist_for_test(stale);

        p.apply(StateUpdate::TelegramOffset(99));
        assert_eq!(
            p.updates_since_persist(),
            0,
            "elapsed-time branch must reset the counter on a single apply"
        );
        assert!(
            dir.path().join("terminus-state.json").exists(),
            "5s-elapsed branch must hit disk on a single apply"
        );
    }

    #[test]
    fn apply_force_propagates_persist_success() {
        let dir = tempdir().unwrap();
        let mut p = fresh_persistor(dir.path());

        p.apply_force(StateUpdate::MarkDirty)
            .expect("startup MarkDirty must persist");
        assert_eq!(p.updates_since_persist(), 0);

        let reloaded = StateStore::load(dir.path().join("terminus-state.json")).unwrap();
        assert!(
            !reloaded.snapshot().last_clean_shutdown,
            "MarkDirty must flip last_clean_shutdown on disk"
        );
    }

    #[test]
    fn mark_clean_shutdown_persists_true() {
        let dir = tempdir().unwrap();
        let mut p = fresh_persistor(dir.path());

        // Simulate prior activity.
        p.apply_force(StateUpdate::MarkDirty).unwrap();
        assert!(!p.snapshot().last_clean_shutdown);

        p.mark_clean_shutdown();
        assert!(p.snapshot().last_clean_shutdown);

        let reloaded = StateStore::load(dir.path().join("terminus-state.json")).unwrap();
        assert!(
            reloaded.snapshot().last_clean_shutdown,
            "mark_clean_shutdown must persist last_clean_shutdown=true"
        );
    }

    #[test]
    fn claim_dirty_send_is_one_shot() {
        let dir = tempdir().unwrap();
        let mut p = fresh_persistor(dir.path());

        assert!(p.claim_dirty_send(), "first claim must succeed");
        for _ in 0..5 {
            assert!(!p.claim_dirty_send(), "subsequent claims must return false");
        }
    }

    #[test]
    fn snapshot_reflects_pre_dirty_state() {
        // Verifies App::new can capture last_clean_shutdown BEFORE applying
        // MarkDirty: persistor::new wraps the store without mutating it.
        // Seed disk explicitly with last_clean_shutdown=false (an unclean
        // prior shutdown) so the assertion fails loudly if the constructor
        // ever starts mutating state — relying on State::default() would
        // make this test vacuously pass if the default ever flipped.
        let dir = tempdir().unwrap();
        let path = dir.path().join("terminus-state.json");
        {
            let mut seed = StateStore::load(&path).unwrap();
            seed.apply(StateUpdate::MarkDirty); // last_clean_shutdown = false
            seed.persist().expect("seed unclean shutdown");
        }

        let store = StateStore::load(&path).unwrap();
        assert!(
            !store.snapshot().last_clean_shutdown,
            "test seed should have written last_clean_shutdown=false"
        );

        let p = StatePersistor::new(store);
        assert!(
            !p.snapshot().last_clean_shutdown,
            "constructing the persistor must not flip the dirty bit"
        );
    }
}
