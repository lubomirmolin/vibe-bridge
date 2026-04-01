use std::sync::{LazyLock, Mutex, MutexGuard};

static TEST_ENV_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

pub(crate) fn lock_test_env() -> MutexGuard<'static, ()> {
    TEST_ENV_LOCK
        .lock()
        .expect("test env lock should not be poisoned")
}
