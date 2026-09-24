# Benchmarks

性能判断に使うworkload、corpus、計測環境、raw result、要約を再現可能な形で保存します。

- [Performance budget（正本）](clair-v2-performance-budget.md) — `make perf-budget` / `make perf-startup`
- [Deterministic corpus recipe](corpus/README.md) — `scripts/benchmarks/generate-corpus.sh`

```text
docs/benchmarks/
├── corpus/
├── results/
│   └── YYYY-MM-DD-environment/
└── <benchmark-name>.md
```

結果にはhardware、OS、build、commit、測定command、試行回数、集計方法を含めます。raw dataは可能な限り機械可読形式で保存し、ADRには結論とこの場所へのリンクだけを記載します。
ccedit V1との比較contractとtext engine baselineは廃止しました（`archive/clair-v1-2026-09-14`から参照可能）。
