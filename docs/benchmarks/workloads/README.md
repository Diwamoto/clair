# Benchmark workloads

この directory は V1 と Clair が共有する操作 contract の正本です。

- [`v1-parity-operation-script.json`](v1-parity-operation-script.json) — M1 parity workload version 1

結果には operation script の相対 path、version、SHA-256 を保存します。V1 と Clair の
`workload_id`、script SHA-256、corpus manifest SHA-256、window size、backing scale、refresh rate が
一致しない場合、数値は `not-comparable` とし、直接の regression 判定に使いません。

JSON は UI automation framework に依存しない操作 contract です。手動 capture でも action ID と
start/end marker を raw result に記録し、省略した action は `not-measured` と理由を残します。
