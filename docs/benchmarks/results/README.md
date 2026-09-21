# Benchmark results

Final load-test evidence is stored in dated subdirectories during
[`L01 Final load and performance`](../../clair-tasks.md#l01-final-load-and-performance).

Text engine surface baselines for the [ADR-0014](../../decisions/0014-clair-owned-text-engine.md)
program are stored the same way, under the profile described in
[text engine surface baseline](../clair-text-engine-baseline.md), and are produced by
`scripts/benchmarks/summarize-engine-baseline.rb`.

No committed result is currently authoritative. Locked-session diagnostics, local
generated corpora, and any result whose `capture.kind` is `example` are not a
performance baseline and must not block PoC feature development.
