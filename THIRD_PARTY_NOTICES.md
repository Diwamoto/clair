# Third-party notices

This file is the source of truth for notices that must accompany distributed
Clair binaries.

## Rust standard library

Clair's Rust static library is built with the Rust standard library. Rust is
available under the Apache License 2.0 or the MIT License, at the user's option.

- Project: https://github.com/rust-lang/rust
- License: https://github.com/rust-lang/rust/blob/master/COPYRIGHT

## Repository dependency policy

The issue #3 bootstrap adds no third-party source package, vendored binary, or
runtime service. Apple SDK frameworks and developer toolchains are build
prerequisites and are not redistributed from this repository.

Any dependency that is linked, embedded, copied, or redistributed must update
this file in the same change. Generated notice artifacts belong under
`.build/generated/` and remain untracked; this file remains tracked.
