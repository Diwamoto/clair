# Clair Agent Notes

This file is read by AI agents working on the Clair repository.

## Dev-environment lifecycle

Clair has several long-running development environments. Starting duplicates wastes resources, clutters the Dock, and can cause port conflicts. Agents must reuse an existing environment when one is already running.

- **Native app (Stable / Dev)**: `make run-stable` launches Stable once, while `make run-dev` starts the Dev watcher, which builds/launches the app and hot-restarts it after native source changes. `scripts/run-app.sh` is idempotent per channel: if an instance of the target bundle is already running, it is brought to the foreground instead of launching a second process. Stable and Dev remain separate bundles and can still run side-by-side.
- **Swift tests**: `make test-swift` launches a single `Clair Dev` host app instance because the `Clair Dev` scheme has test parallelization disabled. The app detects when it is running as an XCTest host and hides its Dock icon and main window, so tests do not clutter the screen. Prefer `make test-swift` over custom `xcodebuild test` invocations. If you must use `xcodebuild` directly, do not pass `-parallel-testing-enabled YES` and do not run multiple test commands concurrently.
- **Interaction Lab mock**: lives in `prototypes/clair-interaction-lab`. Use `scripts/dev-server.sh` to start or reuse its local dev server (default port `5173`). Do not run `npm run dev` directly unless you are certain no server is already listening.
- **Docs site**: lives in `docs-site`. Use `scripts/dev-server.sh` for the same port-reuse behavior.

When you start a long-running environment, track it and stop it at the end of the task unless the user explicitly asks to keep it running. Do not leave orphan Node, Vite, Wrangler, or app processes behind.

## Verification

Prefer narrow, fast checks (`cargo test -p <crate>`, `cargo clippy -p <crate>`, unit tests) during development. Run broader suites (`make test`, `make lint`, `make smoke`) only when finishing a slice or before committing. Do not repeatedly launch the full app or simulator for every small change.
