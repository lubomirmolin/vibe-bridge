use super::*;

impl BridgeAppState {
    pub(super) async fn read_thread_runtime<R>(
        &self,
        thread_id: &str,
        read: impl FnOnce(Option<&CodexThreadRuntime>) -> R,
    ) -> R {
        let runtimes = self.inner.thread_runtimes.read().await;
        read(runtimes.get(thread_id))
    }

    pub(super) async fn update_thread_runtime<R>(
        &self,
        thread_id: &str,
        update: impl FnOnce(&mut CodexThreadRuntime) -> R,
    ) -> R {
        let mut runtimes = self.inner.thread_runtimes.write().await;
        let runtime = runtimes.entry(thread_id.to_string()).or_default();
        let result = update(runtime);
        if runtime.is_empty() {
            runtimes.remove(thread_id);
        }
        result
    }

    pub(super) async fn resumable_notification_threads(&self) -> HashSet<String> {
        let runtimes = self.inner.thread_runtimes.read().await;
        runtimes
            .iter()
            .filter_map(|(thread_id, runtime)| {
                runtime.resumable_notifications.then(|| thread_id.clone())
            })
            .collect()
    }

    pub(super) async fn active_turn_id(&self, thread_id: &str) -> Option<String> {
        let actor_turn_id = self
            .inner
            .gateway
            .thread_lifecycle_state(thread_id)
            .await
            .ok()
            .and_then(|state| state.active_turn_id);
        if actor_turn_id.is_some() {
            return actor_turn_id;
        }
        self.read_thread_runtime(thread_id, |runtime| {
            runtime.and_then(|runtime| runtime.active_turn_id.clone())
        })
        .await
    }

    pub(super) async fn pending_turn_client_message(
        &self,
        thread_id: &str,
    ) -> Option<PendingTurnClientMessage> {
        self.read_thread_runtime(thread_id, |runtime| {
            runtime.and_then(|runtime| runtime.pending_client_message.clone())
        })
        .await
    }

    pub(super) async fn take_pending_user_message_images(&self, thread_id: &str) -> Vec<String> {
        self.update_thread_runtime(thread_id, |runtime| {
            std::mem::take(&mut runtime.pending_user_message_images)
        })
        .await
    }

    pub(super) async fn take_pending_user_input(
        &self,
        thread_id: &str,
    ) -> Option<PendingUserInputSession> {
        self.update_thread_runtime(thread_id, |runtime| runtime.pending_user_input.take())
            .await
    }
}
