---
title: "PTY journal gap後のterminal snapshotとresync方式を決める"
status: planned
related_project: "p0020-mobile-agent-remote-control"
date: 2026-08-27
---

# PTY journal gap後のterminal snapshotとresync方式を決める

## Question

Bounded PTY byte journalの保持範囲を越えて再接続したclientへ、alternate screen、cursor、style、OSC、CJK、wide glyphを壊さず、libghostty macOS viewとmobile rendererの両方で同じterminal stateを復元する最小のsnapshot/resync contractは何か。

## Decision unlocked

- `terminal/snapshot` payload formatとprotocol capability。
- Hostがterminal parser/stateを所有するか、byte journalだけを所有するか。
- Journal容量、checkpoint interval、disk persistenceの要否。
- [ADR-0003](../../decisions/0003-versioned-session-broker-protocol.md)をacceptできるか。

## Hypothesis

Arbitrary raw tail replayはescape sequenceやalternate screenの開始状態を欠くため不十分である。Host側にheadless terminal stateまたは安全なcheckpointを持ち、snapshot + checkpoint以降のbyte replayを組み合わせる方式が、unbounded full-session journalより正確かつboundedになる。

## Compared options

- V1同様にraw tailだけをterminal reset後へreplayする。
- Session epoch開始から全bytesをreplayする。
- Hostがheadless terminal parserを持ち、grid/scrollback/mode snapshotをserializeする。
- Client-specific libghostty state checkpointとportable fallbackを分ける。
- Raw terminalはgap後にtext transcriptへdegradeし、interactive state recoveryを保証しない。

## Environment and corpus

- hardware: Apple silicon Macとtarget iPhoneを記録する。
- OS: target minimum macOS/iOSを決定後に固定する。
- toolchain/build: pinned libghostty commit、mobile terminal renderer/version、Rust/Swift compilerを記録する。
- commit: spike branchのClair commitを記録する。
- fixture/corpus:
  - shell prompt、long-running coding agent TUI、vimまたはalternate-screen fixture
  - ANSI SGR、cursor movement、erase、scroll region、bracketed paste、mouse mode
  - OSC 7/8/52/633、split/mid-sequence gap
  - CJK、emoji、combining character、wide glyph、long line、resize
  - 10 MiB/s floodとslow subscriber

## Method

1. 同一PTY byte corpusをrecordし、候補方式ごとにrandomなdisconnect/gap位置を最低100点生成する。
2. Mac libghostty clientとmobile candidate rendererで、continuous playbackをoracleとしてfinal grid、cursor、mode、scrollback digestを比較する。
3. Snapshot size、生成時間、apply時間、checkpoint CPU/RSS、journal容量を測る。
4. Snapshot chunk中のdisconnect、duplicate、out-of-order、epoch changeを注入し、clientがpartial stateを表示しないことを確認する。
5. Renderer固有stateをserializeする場合、version mismatchとmigration/invalid snapshotのfallbackを検証する。
6. Private terminal contentをdiskへ保存する候補では、encryption、retention、crash artifactを確認する。

## Evidence

Not collected. Raw corpus、result JSON、screen digest、benchmarkは`docs/benchmarks/`へ保存し、この文書からlinkする。

## Results

Pending.

## Analysis

Pending.

## Recommendation

Pending. Correctnessを満たす候補がない場合、initial remote terminalを「cursorがjournal内の接続だけ」にscope縮小し、gap後はsessionへ再attachできないことを明示する。Incorrect screenをsilentに表示する方式は採用しない。

## Limitations

- libghostty embedding API/state serializationはpinned commitごとに変わり得る。
- Different renderer間でpixel-identical表示は要求せず、terminal semantic stateの一致を評価する必要がある。
- Application自身がterminal queryへ応答する場合、passive replayだけでは再現できないstateがあり得る。
