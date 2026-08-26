# Benchmarks

性能判断に使うworkload、corpus、計測環境、raw result、要約を再現可能な形で保存します。

推奨構成:

```text
docs/benchmarks/
├── corpus/
├── results/
│   └── YYYY-MM-DD-environment/
└── <benchmark-name>.md
```

結果にはhardware、OS、build、commit、測定command、試行回数、集計方法を含めます。raw dataは可能な限り機械可読形式で保存し、ADRには結論とこの場所へのリンクだけを記載します。
