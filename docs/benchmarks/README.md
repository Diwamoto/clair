# Benchmarks

性能判断に使うworkload、corpus、計測環境、raw result、要約を再現可能な形で保存します。

Benchmarkは通常の機能sliceの開始条件・完了条件にはしません。PoC期間はbuild、lint、unit、
integration、manual functional smokeだけを実行し、corpus生成、反復timing、Instruments、
ccedit V1とのformal comparisonは
[PoC queueの`L01`](../clair-tasks.md#l01-final-load-and-performance)で一度まとめて行います。
Contract、generator、validatorは将来のL01用toolingとして独立してversion管理し、result取得済みとは扱いません。

[ADR-0014](../decisions/0014-clair-owned-text-engine.md)のtext engine program（`P17`〜`P34`）だけは例外で、
slice単位のsurface計測を行います。手順とcontractは
[text engine surface baseline](clair-text-engine-baseline.md)を正本とし、
`scripts/benchmarks/summarize-engine-baseline.rb`で集計して
`scripts/benchmarks/validate-result.rb`で検証します。この例外を他のitemへ広げません。

Current benchmark contract:

- [ccedit V1 baseline procedure and metric contract](clair-v1-baseline.md)
- [Machine-readable metric contract](metric-contract.json)
- [Clair text engine surface baseline procedure](clair-text-engine-baseline.md)
- [Machine-readable text engine metric contract](text-engine-metric-contract.json)
- [Versioned operation workload](workloads/README.md)
- [Clair / ccedit feature parity matrix](feature-parity-matrix.md)
- [Deterministic corpus recipe](corpus/README.md)

推奨構成:

```text
docs/benchmarks/
├── corpus/
├── results/
│   └── YYYY-MM-DD-environment/
└── <benchmark-name>.md
```

結果にはhardware、OS、build、commit、測定command、試行回数、集計方法を含めます。raw dataは可能な限り機械可読形式で保存し、ADRには結論とこの場所へのリンクだけを記載します。
自動 capture と UI/Instruments evidence を結合する場合は
`scripts/benchmarks/ingest-v1-evidence.rb` を使い、identity、raw sample、timestamp、provenance を
`scripts/benchmarks/validate-result.rb` で再集計・検証します。
