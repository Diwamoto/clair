//! UI-independent foundations shared by Clair frontends and processes.

/// Stable value returned by the bootstrap ABI smoke call (`CLAI` in ASCII).
pub const SMOKE_VALUE: u32 = 0x434C_4149;

/// Returns the value used to verify that the Rust core is linked and callable.
#[must_use]
pub const fn smoke_value() -> u32 {
    SMOKE_VALUE
}

/// Minimal ownership-free ABI used by the native application bootstrap.
///
/// # ABI contract
///
/// This function allocates no memory, retains no pointers, and has no global
/// side effects. Its name, argument list, return width, and value are stable.
#[allow(
    unsafe_code,
    reason = "the exported C ABI requires a stable symbol name"
)]
#[unsafe(no_mangle)]
pub extern "C" fn clair_core_smoke() -> u32 {
    smoke_value()
}

#[cfg(test)]
mod tests {
    use super::{SMOKE_VALUE, clair_core_smoke, smoke_value};

    #[test]
    fn rust_and_c_abi_smoke_values_match() {
        assert_eq!(smoke_value(), SMOKE_VALUE);
        assert_eq!(clair_core_smoke(), SMOKE_VALUE);
    }
}
