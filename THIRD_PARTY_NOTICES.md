# Third-party notices

This file is the source of truth for notices that must accompany distributed
Clair binaries.

## Rust standard library

Clair's Rust static library is built with the Rust standard library. Rust is
available under the Apache License 2.0 or the MIT License, at the user's option.

- Project: https://github.com/rust-lang/rust
- License: https://github.com/rust-lang/rust/blob/master/COPYRIGHT

## libc Rust crate

The local PTY host uses the `libc` Rust crate version `0.2.186` for the macOS
`forkpty`, `ioctl`, signal, and `waitpid` ABI calls. The crate is available
under the Apache License 2.0 or the MIT License, at the user's option.

- Project: https://crates.io/crates/libc
- License: https://github.com/rust-lang/libc/blob/main/LICENSE-APACHE

## Repository dependency policy

The PTY host dependency is resolved through Cargo and is not vendored into this
repository. Apple SDK frameworks and developer toolchains are build prerequisites
and are not redistributed from this repository.

Any dependency that is linked, embedded, copied, or redistributed must update
this file in the same change. Generated notice artifacts belong under
`.build/generated/` and remain untracked; this file remains tracked.
