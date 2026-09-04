# Clair editor bundle

This directory contains the source for Clair's embedded CodeMirror 6 editor.
The setup is adapted from the portable editor portion of ccedit, while the
Swift language definition and Swift-specific folding service live locally in
`src/swift.ts`.

The generated bundle under `apple/ClairApp/EditorWeb` is checked into the
repository because the native app must be buildable without a network
connection. Rebuild it after changing this directory with:

```sh
./scripts/build-editor-web.sh
```

The bundle is loaded by `CodeMirrorEditor.swift` in a local `WKWebView`; it
does not fetch scripts or language definitions at runtime.
