use super::*;

impl BridgeAppState {
    pub fn start_desktop_ipc_forwarder(&self) {
        let Some(desktop_ipc_config) =
            DesktopIpcConfig::detect(self.inner.gateway.desktop_ipc_socket_path())
        else {
            return;
        };

        let state = self.clone();
        let handle = tokio::runtime::Handle::current();
        enum DesktopIpcDispatch {
            ForgetThread(String),
            ForgetThreads(Vec<String>),
            Snapshot {
                snapshot: Box<ThreadSnapshotDto>,
                events: Vec<BridgeEventEnvelope<Value>>,
            },
        }

        let (dispatch_tx, mut dispatch_rx) = tokio_mpsc::unbounded_channel::<DesktopIpcDispatch>();
        let processor_state = self.clone();
        handle.spawn(async move {
            while let Some(message) = dispatch_rx.recv().await {
                match message {
                    DesktopIpcDispatch::ForgetThread(thread_id) => {
                        processor_state
                            .forget_resumable_notification_thread(&thread_id)
                            .await;
                    }
                    DesktopIpcDispatch::ForgetThreads(thread_ids) => {
                        processor_state
                            .forget_resumable_notification_threads(thread_ids)
                            .await;
                    }
                    DesktopIpcDispatch::Snapshot { snapshot, events } => {
                        processor_state
                            .apply_external_snapshot_update(
                                RawThreadEventSource::DesktopIpc,
                                *snapshot,
                                events,
                            )
                            .await;
                    }
                }
            }
        });
        let (control_tx, control_rx) = mpsc::channel();
        *self
            .inner
            .desktop_ipc_control_tx
            .lock()
            .expect("desktop IPC control lock should not be poisoned") = Some(control_tx);

        std::thread::spawn(move || {
            let mut compactor = LiveDeltaCompactor::default();
            let mut conversation_state_by_thread = HashMap::<String, Value>::new();

            loop {
                let mut client = match DesktopIpcClient::connect(&desktop_ipc_config) {
                    Ok(client) => client,
                    Err(error) => {
                        eprintln!("bridge desktop IPC failed to connect: {error}");
                        std::thread::sleep(std::time::Duration::from_secs(2));
                        continue;
                    }
                };

                let mut tracked_threads = {
                    let (reply_tx, reply_rx) = mpsc::sync_channel(1);
                    let state = state.clone();
                    handle.spawn(async move {
                        let _ = reply_tx.send(state.resumable_notification_threads().await);
                    });
                    reply_rx.recv().unwrap_or_default()
                };
                let dropped_threads =
                    match resume_notification_threads(tracked_threads.iter(), |thread_id| {
                        match client.external_resume_thread(thread_id) {
                            Ok(()) => Ok(()),
                            Err(error) if error.contains("no-client-found") => Ok(()),
                            Err(error) => Err(error),
                        }
                    }) {
                        Ok(dropped_threads) => dropped_threads,
                        Err(error) => {
                            eprintln!("bridge desktop IPC resume sync failed: {error}");
                            Vec::new()
                        }
                    };
                if !dropped_threads.is_empty() {
                    for thread_id in &dropped_threads {
                        tracked_threads.remove(thread_id);
                    }
                    let _ = dispatch_tx.send(DesktopIpcDispatch::ForgetThreads(dropped_threads));
                }

                loop {
                    if let Err(error) =
                        drain_notification_control_messages(&control_rx, |message| match message {
                            NotificationControlMessage::ResumeThread(thread_id) => {
                                tracked_threads.insert(thread_id.to_string());
                                if let Some(conversation_state) =
                                    conversation_state_by_thread.get(&thread_id).cloned()
                                {
                                    let previous_snapshot = {
                                        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
                                        let state = state.clone();
                                        let thread_id = thread_id.clone();
                                        handle.spawn(async move {
                                            let _ = reply_tx.send(
                                                state.projections().snapshot(&thread_id).await,
                                            );
                                        });
                                        reply_rx.recv().unwrap_or(None)
                                    };
                                    if previous_snapshot.as_ref().is_some_and(|snapshot| {
                                        snapshot.thread.status == ThreadStatus::Running
                                    }) {
                                        match client.external_resume_thread(&thread_id) {
                                            Ok(()) => Ok(()),
                                            Err(error) if error.contains("no-client-found") => {
                                                Ok(())
                                            }
                                            Err(error) if is_stale_rollout_resume_error(&error) => {
                                                tracked_threads.remove(&thread_id);
                                                let _ = dispatch_tx.send(
                                                    DesktopIpcDispatch::ForgetThread(thread_id),
                                                );
                                                Ok(())
                                            }
                                            Err(error) => Err(error),
                                        }?;
                                        return Ok(());
                                    }
                                    let (previous_summary_status, access_mode, has_bridge_turn) = {
                                        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
                                        let state = state.clone();
                                        let thread_id = thread_id.clone();
                                        handle.spawn(async move {
                                            let summary_status = state
                                                .projections()
                                                .summary_status(&thread_id)
                                                .await;
                                            let access_mode = state.access_mode().await;
                                            let has_bridge_turn = state
                                                .has_bridge_owned_active_turn(&thread_id)
                                                .await;
                                            let _ = reply_tx.send((
                                                summary_status,
                                                access_mode,
                                                has_bridge_turn,
                                            ));
                                        });
                                        reply_rx.recv().unwrap_or((
                                            None,
                                            AccessMode::ReadOnly,
                                            false,
                                        ))
                                    };
                                    let latest_raw_turn_status = conversation_state
                                        .get("turns")
                                        .and_then(Value::as_array)
                                        .and_then(|turns| turns.last())
                                        .and_then(raw_turn_status)
                                        .map(ToString::to_string);
                                    if let Ok((next_snapshot, events)) =
                                        build_desktop_ipc_snapshot_update(
                                            previous_snapshot.as_ref(),
                                            previous_summary_status,
                                            &conversation_state,
                                            access_mode,
                                            &mut compactor,
                                            false,
                                            latest_raw_turn_status.as_deref(),
                                            has_bridge_turn,
                                        )
                                    {
                                        let _ = dispatch_tx.send(DesktopIpcDispatch::Snapshot {
                                            snapshot: Box::new(next_snapshot),
                                            events,
                                        });
                                    }
                                }
                                match client.external_resume_thread(&thread_id) {
                                    Ok(()) => Ok(()),
                                    Err(error) if error.contains("no-client-found") => Ok(()),
                                    Err(error) if is_stale_rollout_resume_error(&error) => {
                                        tracked_threads.remove(&thread_id);
                                        let _ = dispatch_tx
                                            .send(DesktopIpcDispatch::ForgetThread(thread_id));
                                        Ok(())
                                    }
                                    Err(error) => Err(error),
                                }
                            }
                        })
                    {
                        eprintln!("bridge desktop IPC control failed: {error}");
                        break;
                    }

                    let next_change = match client.next_thread_stream_state_changed() {
                        Ok(change) => change,
                        Err(error) => {
                            eprintln!("bridge desktop IPC stream failed: {error}");
                            break;
                        }
                    };
                    let Some(change) = next_change else {
                        continue;
                    };
                    let thread_id = change.conversation_id.clone();
                    let is_patch_update =
                        matches!(&change.change, DesktopStreamChange::Patches { .. });
                    let next_state = match change.change {
                        DesktopStreamChange::Snapshot { conversation_state } => {
                            Some(conversation_state)
                        }
                        DesktopStreamChange::Patches { patches } => {
                            let Some(mut conversation_state) =
                                conversation_state_by_thread.get(&thread_id).cloned()
                            else {
                                continue;
                            };
                            if let Err(error) = apply_patches(&mut conversation_state, &patches) {
                                eprintln!(
                                    "bridge desktop IPC patch apply failed for {thread_id}: {error}"
                                );
                                conversation_state_by_thread.remove(&thread_id);
                                continue;
                            }
                            Some(conversation_state)
                        }
                    };
                    let Some(conversation_state) = next_state else {
                        continue;
                    };
                    conversation_state_by_thread
                        .insert(thread_id.clone(), conversation_state.clone());
                    if !tracked_threads.contains(&thread_id) {
                        continue;
                    }

                    let (previous_snapshot, previous_summary_status, access_mode, has_bridge_turn) = {
                        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
                        let state = state.clone();
                        let thread_id = thread_id.clone();
                        handle.spawn(async move {
                            let snapshot = state.projections().snapshot(&thread_id).await;
                            let summary_status =
                                state.projections().summary_status(&thread_id).await;
                            let access_mode = state.access_mode().await;
                            let has_bridge_turn =
                                state.has_bridge_owned_active_turn(&thread_id).await;
                            let _ = reply_tx.send((
                                snapshot,
                                summary_status,
                                access_mode,
                                has_bridge_turn,
                            ));
                        });
                        reply_rx
                            .recv()
                            .unwrap_or((None, None, AccessMode::ReadOnly, false))
                    };
                    let latest_raw_turn_status = conversation_state
                        .get("turns")
                        .and_then(Value::as_array)
                        .and_then(|turns| turns.last())
                        .and_then(raw_turn_status)
                        .map(ToString::to_string);
                    let (next_snapshot, events) = match build_desktop_ipc_snapshot_update(
                        previous_snapshot.as_ref(),
                        previous_summary_status,
                        &conversation_state,
                        access_mode,
                        &mut compactor,
                        is_patch_update,
                        latest_raw_turn_status.as_deref(),
                        has_bridge_turn,
                    ) {
                        Ok(update) => update,
                        Err(error) => {
                            eprintln!(
                                "bridge desktop IPC snapshot mapping failed for {thread_id}: {error}"
                            );
                            continue;
                        }
                    };

                    let _ = dispatch_tx.send(DesktopIpcDispatch::Snapshot {
                        snapshot: Box::new(next_snapshot),
                        events,
                    });
                }

                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        });
    }

    pub fn start_summary_reconciler(&self) {
        let state = self.clone();
        tokio::spawn(async move {
            loop {
                sleep(Duration::from_secs(30)).await;
                match state.inner.gateway.bootstrap().await {
                    Ok(bootstrap) => {
                        let current_summaries = state.projections().list_summaries().await;
                        let preserved_summaries = merge_reconciled_thread_summaries(
                            current_summaries,
                            bootstrap.summaries,
                        );
                        state
                            .projections()
                            .replace_summaries(preserved_summaries)
                            .await;
                        state.set_available_models(bootstrap.models).await;
                        state
                            .set_codex_health(ServiceHealthDto {
                                status: ServiceHealthStatus::Healthy,
                                message: bootstrap.message,
                            })
                            .await;
                    }
                    Err(error) => {
                        state
                            .set_codex_health(ServiceHealthDto {
                                status: ServiceHealthStatus::Degraded,
                                message: Some(format!("summary reconcile failed: {error}")),
                            })
                            .await;
                    }
                }
            }
        });
    }
}
