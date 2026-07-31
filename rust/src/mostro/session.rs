/// Per-trade session state management.
///
/// Each active trade has a `Session` that tracks the order, role, keys,
/// and peer identity. Sessions are created when a trade is taken and
/// cleaned up on completion, cancellation, or timeout.
use anyhow::{anyhow, Result};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::api::types::{OrderInfo, OrderStatus, TradeRole};

/// Per-trade session state.
#[derive(Clone)]
pub struct Session {
    pub order_id: String,
    pub role: TradeRole,
    pub trade_key_index: u32,
    /// ECDH shared key with peer (computed when peer pubkey received
    /// from Mostro via `hold-invoice-payment-accepted` action).
    pub shared_key: Option<[u8; 32]>,
    /// ECDH shared key with admin (for dispute chat).
    pub admin_shared_key: Option<[u8; 32]>,
    /// Peer's public key (hex).
    pub peer_pubkey: Option<String>,
    /// Original order snapshot.
    pub order: OrderInfo,
    /// Unix timestamp when the session was created.
    pub created_at: i64,
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session")
            .field("order_id", &self.order_id)
            .field("role", &self.role)
            .field("trade_key_index", &self.trade_key_index)
            .field("shared_key", &self.shared_key.as_ref().map(|_| "<REDACTED>"))
            .field("admin_shared_key", &self.admin_shared_key.as_ref().map(|_| "<REDACTED>"))
            .field("peer_pubkey", &self.peer_pubkey)
            .field("order", &self.order)
            .field("created_at", &self.created_at)
            .finish()
    }
}

// ── Cancel cleanup policy ───────────────────────────────────────────────────

/// On a timeout slash the daemon sends `canceled` first and `bond-slashed`
/// milliseconds later. Dropping the session on `canceled` would take the trade
/// key out of the subscription filter and discard its decryption key, so the
/// trailing notice could never be received.
pub const BOND_SLASH_GRACE_SECS: i64 = 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CancelCleanup {
    Immediate,
    Defer,
    /// Dispute and admin states still need the session's keys for the admin chat.
    Keep,
}

/// Decides a session's fate from the order status recorded *before* the cancel
/// was applied.
pub fn cancel_cleanup(status: Option<&OrderStatus>) -> CancelCleanup {
    match status {
        Some(
            OrderStatus::Dispute
            | OrderStatus::CanceledByAdmin
            | OrderStatus::SettledByAdmin
            | OrderStatus::CompletedByAdmin,
        ) => CancelCleanup::Keep,
        Some(OrderStatus::Pending) => CancelCleanup::Immediate,
        _ => CancelCleanup::Defer,
    }
}

/// Sessions and their pending removals share one lock: a retake racing the
/// grace deadline must never observe one map mid-update against the other.
#[derive(Default)]
struct SessionState {
    sessions: HashMap<String, Session>,
    /// Order id -> unix deadline past which the deferred session is dropped.
    deferred_removals: HashMap<String, i64>,
}

/// In-memory session store.
pub struct SessionManager {
    state: Arc<RwLock<SessionState>>,
}

impl Default for SessionManager {
    fn default() -> Self { Self::new() }
}

impl SessionManager {
    pub fn new() -> Self {
        Self {
            state: Arc::new(RwLock::new(SessionState::default())),
        }
    }

    /// Create a new session for a trade. Returns an error if a session
    /// already exists for this order (indicates duplicate processing).
    pub async fn create_session(
        &self,
        order_id: String,
        role: TradeRole,
        trade_key_index: u32,
        order: OrderInfo,
    ) -> Result<Session> {
        if order_id != order.id {
            return Err(anyhow!(
                "order_id mismatch: param='{}' vs order.id='{}'",
                order_id,
                order.id
            ));
        }

        let now = crate::rt::unix_now();

        let session = Session {
            order_id: order_id.clone(),
            role,
            trade_key_index,
            shared_key: None,
            admin_shared_key: None,
            peer_pubkey: None,
            order,
            created_at: now,
        };

        let mut state = self.state.write().await;
        // A session awaiting deferred removal belongs to the canceled take;
        // this one supersedes it, deadline included.
        if state.deferred_removals.remove(&order_id).is_some() {
            state.sessions.remove(&order_id);
        }
        if state.sessions.contains_key(&order_id) {
            return Err(anyhow!("SessionAlreadyExists: {}", order_id));
        }
        state.sessions.insert(order_id, session.clone());
        Ok(session)
    }

    /// Update an existing session.
    pub async fn update_session(&self, order_id: &str, session: Session) -> Result<()> {
        if session.order_id != order_id {
            return Err(anyhow!(
                "SessionOrderIdMismatch: param='{}' vs session.order_id='{}'",
                order_id,
                session.order_id
            ));
        }
        let mut state = self.state.write().await;
        if !state.sessions.contains_key(order_id) {
            return Err(anyhow!("SessionNotFound"));
        }
        state.sessions.insert(order_id.to_string(), session);
        Ok(())
    }

    /// Get a session by order ID.
    pub async fn get_session(&self, order_id: &str) -> Option<Session> {
        self.state.read().await.sessions.get(order_id).cloned()
    }

    /// Remove a session (on completion, cancellation, or timeout).
    pub async fn remove_session(&self, order_id: &str) {
        let mut state = self.state.write().await;
        state.deferred_removals.remove(order_id);
        state.sessions.remove(order_id);
    }

    /// Defer this session's removal until `delay_secs` from now.
    pub async fn defer_removal(&self, order_id: &str, delay_secs: i64) {
        let deadline = crate::rt::unix_now() + delay_secs;
        self.state
            .write()
            .await
            .deferred_removals
            .insert(order_id.to_string(), deadline);
    }

    /// Settle a deferred removal early. Reports whether one was pending; a
    /// session with no deferred removal is left untouched.
    pub async fn resolve_deferred_removal(&self, order_id: &str) -> bool {
        let mut state = self.state.write().await;
        let was_deferred = state.deferred_removals.remove(order_id).is_some();
        if was_deferred {
            state.sessions.remove(order_id);
        }
        was_deferred
    }

    /// Drop every session whose deferred deadline has elapsed.
    pub async fn reconcile_deferred_removals(&self) {
        let now = crate::rt::unix_now();
        let mut state = self.state.write().await;
        let due: Vec<String> = state
            .deferred_removals
            .iter()
            .filter(|(_, &deadline)| now >= deadline)
            .map(|(order_id, _)| order_id.clone())
            .collect();
        for order_id in &due {
            state.deferred_removals.remove(order_id);
            state.sessions.remove(order_id);
        }
    }

    /// Store the ECDH admin shared key derived from `adminTookDispute`.
    ///
    /// Called by the event handler when the daemon assigns an admin to the
    /// dispute. The key is derived from the trade BIP-32 key and the admin's
    /// Nostr public key using NIP-44 v2 ECDH.
    pub async fn set_admin_shared_key(
        &self,
        order_id: &str,
        key: [u8; 32],
    ) -> Result<()> {
        let mut state = self.state.write().await;
        let session = state
            .sessions
            .get_mut(order_id)
            .ok_or_else(|| anyhow!("SessionNotFound: {order_id}"))?;
        session.admin_shared_key = Some(key);
        Ok(())
    }

    /// Remove sessions older than `timeout_secs` that have no shared key
    /// (i.e., the take action was never acknowledged by Mostro).
    pub async fn cleanup_stale_sessions(&self, timeout_secs: i64) {
        let now = crate::rt::unix_now();

        let mut state = self.state.write().await;
        state.sessions.retain(|_, s| {
            s.shared_key.is_some() || (now - s.created_at) < timeout_secs
        });
    }
}

// ── Global singleton ────────────────────────────────────────────────────────

use std::sync::OnceLock;

static SESSION_MGR: OnceLock<SessionManager> = OnceLock::new();

/// Get the global session manager.
pub fn session_manager() -> &'static SessionManager {
    SESSION_MGR.get_or_init(SessionManager::new)
}

/// Register a deferred removal and arm the timer that enforces it.
///
/// Registration is awaited so a `bond-slashed` arriving right after the cancel
/// always finds the deferral armed; only the deadline runs in the background.
pub async fn defer_session_removal(order_id: String, delay_secs: i64) {
    session_manager().defer_removal(&order_id, delay_secs).await;
    crate::rt::spawn(async move {
        crate::rt::time::sleep(crate::rt::time::Duration::from_secs(
            delay_secs.max(0) as u64
        ))
        .await;
        session_manager().reconcile_deferred_removals().await;
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::types::OrderKind;

    fn dummy_order_info(id: &str) -> OrderInfo {
        OrderInfo {
            id: id.to_string(),
            kind: OrderKind::Buy,
            status: OrderStatus::Pending,
            fiat_code: "USD".to_string(),
            fiat_amount: Some(100.0),
            fiat_amount_min: None,
            fiat_amount_max: None,
            payment_method: "Bank".to_string(),
            premium: 0.0,
            is_mine: false,
            created_at: 0,
            expires_at: None,
            amount_sats: None,
            creator_pubkey: String::new(),
            rating: 0.0,
            total_reviews: 0,
            days_active: 0,
        }
    }

    async fn manager_with_session(order_id: &str) -> SessionManager {
        let mgr = SessionManager::new();
        mgr.create_session(
            order_id.to_string(),
            TradeRole::Buyer,
            0,
            dummy_order_info(order_id),
        )
        .await
        .expect("create_session");
        mgr
    }

    #[test]
    fn dispute_and_admin_states_keep_the_session() {
        for status in [
            OrderStatus::Dispute,
            OrderStatus::CanceledByAdmin,
            OrderStatus::SettledByAdmin,
            OrderStatus::CompletedByAdmin,
        ] {
            assert_eq!(cancel_cleanup(Some(&status)), CancelCleanup::Keep);
        }
    }

    #[test]
    fn a_pending_cancel_returns_the_bond_and_drops_the_session() {
        assert_eq!(
            cancel_cleanup(Some(&OrderStatus::Pending)),
            CancelCleanup::Immediate
        );
    }

    #[test]
    fn committed_and_unknown_states_defer() {
        for status in [
            Some(OrderStatus::WaitingBuyerInvoice),
            Some(OrderStatus::WaitingPayment),
            Some(OrderStatus::Active),
            Some(OrderStatus::FiatSent),
            Some(OrderStatus::InProgress),
            None,
        ] {
            assert_eq!(cancel_cleanup(status.as_ref()), CancelCleanup::Defer);
        }
    }

    #[tokio::test]
    async fn a_deferred_session_survives_until_its_deadline() {
        let order_id = "order-deferred";
        let mgr = manager_with_session(order_id).await;

        mgr.defer_removal(order_id, BOND_SLASH_GRACE_SECS).await;
        mgr.reconcile_deferred_removals().await;

        assert!(
            mgr.get_session(order_id).await.is_some(),
            "the session must outlive the cancel so a trailing bond-slashed can be decrypted"
        );
    }

    #[tokio::test]
    async fn a_deferred_session_is_dropped_once_the_deadline_passes() {
        let order_id = "order-expired";
        let mgr = manager_with_session(order_id).await;

        mgr.defer_removal(order_id, 0).await;
        mgr.reconcile_deferred_removals().await;

        assert!(mgr.get_session(order_id).await.is_none());
    }

    #[tokio::test]
    async fn resolving_a_deferral_drops_the_session_immediately() {
        let order_id = "order-slashed";
        let mgr = manager_with_session(order_id).await;

        mgr.defer_removal(order_id, BOND_SLASH_GRACE_SECS).await;

        assert!(mgr.resolve_deferred_removal(order_id).await);
        assert!(mgr.get_session(order_id).await.is_none());
    }

    #[tokio::test]
    async fn resolving_without_a_deferral_leaves_the_session_alone() {
        let order_id = "order-live";
        let mgr = manager_with_session(order_id).await;

        assert!(!mgr.resolve_deferred_removal(order_id).await);
        assert!(
            mgr.get_session(order_id).await.is_some(),
            "a live trade must not lose its session to an unrelated bond-slashed"
        );
    }

    async fn retake(mgr: &SessionManager, order_id: &str) -> Result<Session> {
        mgr.create_session(
            order_id.to_string(),
            TradeRole::Seller,
            7,
            dummy_order_info(order_id),
        )
        .await
    }

    /// Retaking the same order inside the grace window must not lose the fresh
    /// session to the canceled take's timer.
    #[tokio::test]
    async fn a_retake_supersedes_the_deferred_session() {
        let order_id = "order-retaken";
        let mgr = manager_with_session(order_id).await;

        mgr.defer_removal(order_id, BOND_SLASH_GRACE_SECS).await;
        retake(&mgr, order_id).await.expect("retake");

        mgr.reconcile_deferred_removals().await;

        let session = mgr.get_session(order_id).await.expect("session kept");
        assert_eq!(session.trade_key_index, 7);
    }

    /// A retake landing on an already-elapsed deadline — the window a separate
    /// deferral and session lock left open — still ends up with a live session.
    #[tokio::test]
    async fn a_retake_at_the_deadline_keeps_its_session() {
        let order_id = "order-retaken-late";
        let mgr = manager_with_session(order_id).await;

        mgr.defer_removal(order_id, 0).await;
        retake(&mgr, order_id).await.expect("retake");

        mgr.reconcile_deferred_removals().await;

        let session = mgr.get_session(order_id).await.expect("session kept");
        assert_eq!(session.trade_key_index, 7);
    }

    /// A live session is not a stale deferral: the duplicate guard still holds.
    #[tokio::test]
    async fn a_retake_over_a_live_session_is_still_refused() {
        let order_id = "order-live-take";
        let mgr = manager_with_session(order_id).await;

        let err = retake(&mgr, order_id).await.expect_err("duplicate take");

        assert!(err.to_string().contains("SessionAlreadyExists"));
    }

    #[tokio::test]
    async fn removing_a_session_clears_its_pending_deferral() {
        let order_id = "order-removed";
        let mgr = manager_with_session(order_id).await;

        mgr.defer_removal(order_id, BOND_SLASH_GRACE_SECS).await;
        mgr.remove_session(order_id).await;

        assert!(!mgr.resolve_deferred_removal(order_id).await);
    }
}
