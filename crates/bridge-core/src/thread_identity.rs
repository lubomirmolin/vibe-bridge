use shared_contracts::ProviderKind;

pub(crate) fn provider_thread_id(provider: ProviderKind, native_id: &str) -> String {
    format!("{}:{native_id}", provider_prefix(provider))
}

pub(crate) fn provider_prefix(provider: ProviderKind) -> &'static str {
    match provider {
        ProviderKind::Codex => "codex",
        ProviderKind::ClaudeCode => "claude",
    }
}

pub(crate) fn provider_from_thread_id(thread_id: &str) -> Option<ProviderKind> {
    let (prefix, _) = thread_id.split_once(':')?;
    match prefix {
        "codex" => Some(ProviderKind::Codex),
        "claude" => Some(ProviderKind::ClaudeCode),
        _ => None,
    }
}

pub(crate) fn native_thread_id_for_provider<'a>(
    thread_id: &'a str,
    provider: ProviderKind,
) -> Option<&'a str> {
    match provider_from_thread_id(thread_id) {
        Some(found_provider) if found_provider == provider => {
            thread_id.split_once(':').map(|(_, native_id)| native_id)
        }
        None if provider == ProviderKind::Codex => Some(thread_id),
        _ => None,
    }
}

pub(crate) fn is_provider_thread_id(thread_id: &str, provider: ProviderKind) -> bool {
    native_thread_id_for_provider(thread_id, provider).is_some()
}
