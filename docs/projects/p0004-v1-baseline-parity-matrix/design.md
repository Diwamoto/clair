# Design

## Current state

着手時の Clair には benchmark の置き場所を示す README と、同一 fixture/操作 script で V1 と比較する
[ADR-0001](../../decisions/0001-adopt-swiftui-appkit-frontend.md) だけがあり、corpus、raw
result schema、feature matrix、再実行用 command はなかった。本 project でそれらを repository-owned
contract として追加する。

ccedit V1 には launch/setup と frontend first-paint を記録する performance log があり、固定
commit `80eef4d30f66c4520445872bed73e95c594e2695` を baseline source として再 build できる。
V1 の UI は Tauri/WebView + xterm.js + CodeMirror であり、frame/drop/input latency は process
log だけでは完全に測れないため、OS trace/manual capture と自動値を分けて保存する。

## Proposed design

```text
scripts/benchmarks/generate-corpus.sh
        │
        ▼
.build/benchmarks/corpus/  (generated; never committed)
        │
        ├── large files / Unicode fixture / file tree / Git status fixture
        └── same paths and bytes for V1 and Clair

V1 app + benchmark namespace + OS sandbox ── collect-v1-baseline.sh ── automated JSON
                                                                            │
Instruments/manual UI evidence ── sanitized evidence JSON ──────────────────┤
                                                                            ▼
                                                           ingest-v1-evidence.rb
                                                                            │
                                                                            ▼
docs/benchmarks/results/<date>-<source>/
        │
        ├── baseline.json
        └── README.md / summary links
```

The procedure has three layers:

1. `generate-corpus.sh` creates all deterministic input data and a Git working
   state without modifying a user repository.
2. `collect-v1-baseline.sh` runs the benchmark-only bundle under a macOS sandbox
   that denies the operator's normal HOME, then captures environment,
   source/build identity, app lifecycle log phases, and raw RSS/CPU/process samples.
3. `v1-parity-operation-script.json` fixes UI action IDs, geometry, input,
   byte counts, fixture paths, and markers. `clair-v1-baseline.md` explains the
   Instruments/manual execution for metrics needing rendered frames, keyboard
   input, or PTY reconnect. A future Clair slice reuses these exact contracts.
4. `ingest-v1-evidence.rb` binds sanitized UI/Instruments samples to an unlocked
   automated result, recalculates summary/coverage, and refuses identity,
   provenance, display, unit, or sample-policy mismatches.

The baseline app is built from the pinned V1 source in release mode. When the
normal V1 bundle is already running, the benchmark build may use a unique
benchmark bundle identifier. The result records that override so the measured
code and the measured identity are not confused.

## Components and responsibilities

| Component | Responsibility | Changed interface |
|---|---|---|
| `scripts/benchmarks/generate-corpus.sh` | Create deterministic synthetic files, tree, Unicode fixture, and Git status state | CLI `--output <directory>` |
| `scripts/benchmarks/collect-v1-baseline.sh` | Run a benchmark-only V1 app under an OS sandbox and preserve raw lifecycle/process samples | CLI `--app`, `--source-commit`, `--corpus`, `--operation-script`, `--metric-contract`, `--output` |
| `scripts/benchmarks/ingest-v1-evidence.rb` | Bind sanitized unlocked UI/Instruments evidence to one validated automated result and recalculate summaries | CLI `--base`, `--evidence`, `--output` |
| `scripts/benchmarks/validate-result.rb` | Validate raw JSON structure and required identity fields | CLI `<result.json>` |
| `docs/benchmarks/metric-contract.json` | Define canonical metric names, units, sample policy, aggregation, and comparison direction | Schema 1 metric registry |
| `docs/benchmarks/workloads/v1-parity-operation-script.json` | Fix cross-implementation UI/workload actions and comparison identity | Schema 1 operation contract |
| `docs/benchmarks/clair-v1-baseline.md` | Canonical measurement procedure, metric contract, and V1 summary | Documentation contract |
| `docs/benchmarks/feature-parity-matrix.md` | Canonical M1 capability classification | Documentation contract |
| `docs/benchmarks/results/` | Store raw machine-readable evidence and environment record | Versioned result schema 1 |
| `docs/projects/p0004-v1-baseline-parity-matrix/` | Preserve implementation handoff and completion evidence | Project bundle |

## Data and control flow

1. The operator checks out the pinned V1 source without changing the source
   repository and builds an unsigned release app with an isolated benchmark
   identifier if needed.
2. The operator creates the corpus under `.build/benchmarks/corpus`.
3. For each fresh-profile trial, benchmark-only app data/cache/WebKit state is new.
   This does not claim a filesystem-cache cold launch. For warm trials, the same
   benchmark profile is relaunched after one excluded warm-up.
4. The collector samples app RSS/CPU and records V1 log phases. The operator
   separately records frame/input/energy/reattach evidence using the procedure.
5. The ingester requires an unlocked session, matching source/workload/host/display
   identity, timestamped raw samples, and provenance before combining the evidence.
6. The result validator checks that every metric is either a numeric observation
   with unit metadata or an explicit `not-measured` record with a reason.
7. Summary values are derived from raw trials or evidence samples. No raw user data, terminal
   transcript, or private path is copied into the result.

## Interfaces and contracts

### Corpus contract

The generator creates these stable paths:

- `large-files/text-10MiB.txt` — exactly `10_485_760` bytes.
- `large-files/text-100MiB.txt` — exactly `104_857_600` bytes.
- `unicode/unicode-fixture.txt` — CJK, emoji, combining marks, full-width and box-drawing rendering text.
- `unicode/ime-operations.json` — marked-text update/commit/cancel and offset expectations.
- `terminal/flood-1MiB.txt` and `terminal/osc-sequences.bin` — fixed flood and OSC 52/633 bytes.
- `file-tree/` — 10,000 deterministic files across 200 directories and three levels below root.
- `git-status/` — a local repository with a committed baseline plus modified, deleted, renamed, and untracked entries.

The generated root contains `MANIFEST.json` with byte sizes, relative paths,
generator version, and SHA-256 values. The `.git` directory is local fixture
state and is never copied into raw result files.

### Raw result contract

`baseline.json` uses `schema_version: 1`. Top-level keys are `source`,
`environment`, `workload`, `runs`, `summary`, and `coverage`, with optional
`evidence` for unlocked UI/Instruments observations. Runs retain raw
process samples and bounded V1 perf events; summary records name its sample
count and aggregation source. A metric record
uses `{ "status": "measured", "value": <number>, "unit": <string> }` or
`{ "status": "not-measured", "reason": <string> }`. A measured value without
unit or a missing reason is invalid.

The source commit is always a full 40-character SHA. Host-local paths are
reduced to labels or omitted. The `build.identity_override` field is required
when the benchmark bundle differs from the normal V1 bundle.

Evidence is additive and never mutates the source automated result. It records
the base byte SHA, matching source/corpus/operation/metric/hardware/OS/display
identity, canonical action and metric IDs, raw samples, RFC 3339 timestamps, and
manual/Instruments provenance. A metric may be sourced by automated runs or
evidence, never both.

### Metric contract

The canonical names and aggregation rules live in
[metric-contract.json](../../benchmarks/metric-contract.json) and are explained by
[clair-v1-baseline.md](../../benchmarks/clair-v1-baseline.md). Five-trial workloads
report median and max. A nearest-rank p95 is permitted only from at least 20 raw
samples. Resource values report median and max. A future performance gate compares
only matching metric/unit/build/workload/corpus/display identities; it does not
compare unlike captures or silently treat missing evidence as zero.

## State, persistence, and migration

Generated corpus, benchmark-only app state, app logs, and Instruments traces are disposable
and stay outside the committed result. Only sanitized environment metadata, raw
numeric samples, and summary are persisted under `docs/benchmarks/results/`.
There is no migration or compatibility promise for pre-project benchmark files;
the schema version and validator provide an explicit update seam.

## Failure handling and recovery

- Missing app, source commit, corpus tool, or required host command fails before
  writing a misleading result.
- An app that exits before first paint is recorded as a failed run with exit
  status and log phase coverage; it is not reported as a zero-millisecond launch.
- Instruments or Accessibility permission failures produce `not-measured` with
  the exact capability reason and leave other observations intact.
- A partial run can be discarded and rerun with a new result directory. The
  procedure never removes user data or the existing ccedit checkout.

## Security and privacy

Corpus content is synthetic. The collector refuses the normal V1/Dev identifiers,
creates a previously absent benchmark-only namespace, and applies an OS sandbox
that denies read/write access to the operator's HOME except that namespace. It
stores only sanitized phase names and numeric samples. It does not ingest normal
ccedit logs, history, shell history, or repository files. Existing benchmark data
also causes a fail-closed stop instead of being reused.

## Observability

The raw result retains source/build/environment identity, trial status, metric
coverage, and a bounded list of V1 log phase names/values. The summary links to
raw JSON and states which metrics are measured, manual, or unavailable. Trace
files are not committed; their export summaries may be added later under the
same result directory.

## Test strategy

- `bash -n` validates benchmark shell scripts.
- The corpus generator is run into a temporary directory; a manifest check
  verifies exact sizes, stable paths, Unicode markers, and Git fixture state.
- `ruby scripts/benchmarks/validate-result.rb <result.json>` validates the raw
  result schema.
- `ruby scripts/benchmarks/ingest-v1-evidence.rb ...` is exercised with valid
  unlocked evidence and negative identity, provenance, sample, summary, and
  coverage cases before accepting UI results.
- The operation and metric contracts are parsed as JSON and their SHA-256 values
  are recorded by the result.
- Markdown links, YAML front matter, and whitespace are checked with the same
  repository checks used by the native workspace.
- One V1 baseline capture is performed on the documented Apple Silicon host;
  future Clair captures repeat the same procedure and five-trial policy.

## Options considered

### Option A: Repository-owned corpus and shell/JSON measurement contract

- Advantages: works for V1 and future native builds, reviewable in Git, easy to
  run from a clean checkout, and keeps large generated data out of the repository.
- Disadvantages: rendered frame and input latency still need Instruments or a
  UI-capable manual step.
- Evidence: ADR-0001 requires identical fixtures and operation scripts, while
  the current V1 and Clair do not share an instrumentation API.

### Option B: Use only ccedit application logs

- Advantages: simple and already available for launch/setup phases.
- Disadvantages: cannot establish frame drops, keyboard-to-glyph latency,
  energy impact, or a comparable PTY reattach result; logs also include
  host-specific private paths.
- Evidence: V1 `perf` logs expose frontend/backend phases but not a complete
  rendered-frame trace.

### Option C: Commit full generated 10 MiB/100 MiB corpus and trace files

- Advantages: one checkout contains every byte and recording.
- Disadvantages: repository size, privacy risk, and machine-specific traces
  make review and reruns worse; a generator is more durable than a binary dump.
- Evidence: `docs/benchmarks/README.md` recommends a corpus recipe and raw
  machine-readable result, not unbounded generated artifacts.

## Decision and rationale

Use Option A. Keep the V1 source pin, corpus recipe, metric/result contract,
and sanitized raw observations in Git. Use explicit coverage states for metrics
that require Instruments or a GUI capability. This preserves auditability without
pretending that a headless process sample measures rendered frame quality.

## Risks and mitigations

| Risk | Impact | Mitigation or exit condition |
|---|---|---|
| V1 build changes outside the pinned source | Baseline is not comparable | Record full commit and build identity; refuse missing commit |
| OS or thermal state skews results | False regression/improvement | Same host, idle precondition, five trials, environment record, median/max; p95 only for n >= 20 |
| UI trace permission is unavailable | Coverage gap | Record `not-measured`; repeat on an approved GUI host before setting gates |
| Large corpus is accidentally committed | Repository bloat | Generate only under ignored `.build/benchmarks`; validator checks manifest rather than binary presence |
| Existing ccedit process captures the same bundle identity | Cross-run interference | Refuse normal identifiers, use a unique benchmark identity and sandboxed namespace, record the override |

## Rollout and rollback

Land the documentation, scripts, parity matrix, and one sanitized V1 result as
one benchmark slice. Future projects append a new dated result directory and do
not rewrite the V1 source pin. Rollback is removing only this project's files;
generated corpus, benchmark-only app state, and traces are disposable.

## Documentation impact

- Update [benchmarks README](../../benchmarks/README.md) with procedure, matrix,
  corpus, and result links.
- Add [V1 benchmark procedure](../../benchmarks/clair-v1-baseline.md).
- Add [feature parity matrix](../../benchmarks/feature-parity-matrix.md).
- Add [corpus recipe](../../benchmarks/corpus/README.md) and raw result metadata.
- Add machine-readable [metric contract](../../benchmarks/metric-contract.json) and
  [operation script](../../benchmarks/workloads/v1-parity-operation-script.json).
- No architecture, product, or accepted ADR is rewritten.

## Open questions

None.
