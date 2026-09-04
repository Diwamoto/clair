---
title: "Clair host-mobile pairingとE2EE remote linkを選定する"
status: planned
related_project: "p0020-mobile-agent-remote-control"
date: 2026-08-27
---

# Clair host-mobile pairingとE2EE remote linkを選定する

## Question

Untrusted relayを経由し、Mac/iOSで保守可能なlibraryを使って、QR pairing、mutual device authentication、forward secrecy、replay protection、scope binding、lost-device revocationを実現するprotocolとkey lifecycleは何か。

## Decision unlocked

- [ADR-0004](../../decisions/0004-outbound-e2ee-relay.md)のaccept/修正。
- QR payload、handshake、device identity、session key、rotation、revocation generationのwire contract。
- Keychain/Secure Enclaveの利用範囲とfallback。
- Relay ciphertext queue、TTL、push wake token、step-up proofのsecurity boundary。

## Hypothesis

Established authenticated key-exchange protocolをapplication layerで使い、long-term device identityとephemeral session keyを分離すれば、relay-terminated TLSだけに依存せず要件を満たせる。Algorithmを独自に組み合わせるのではなく、Mac/iOS/Rustで継続保守されているimplementationとtest vectorがある方式を選ぶ必要がある。

## Compared options

- Authenticated Noise handshake familyを既存libraryで使う。
- Mutual TLSでdeviceを認証し、別のaudited application payload encryptionを重ねる。
- WebRTC DTLS/data channelとTURNを使う。
- Private-network TLSだけにinitial scopeを限定し、internet relayを延期する。
- Relay-terminated TLSだけを使う案はE2EE要件を満たさないcontrol optionとして比較する。

## Environment and corpus

- hardware: Secure Enclave対応Apple silicon Mac、target iPhone、Secure Enclave非対応test environment。
- OS: target minimum macOS/iOS。
- toolchain/build: Rust crypto library、Swift package、OS crypto APIのversionとlicenseを固定する。
- commit: spike branchのClair commit。
- fixture/corpus:
  - Official test vectorとcross-language interop vector
  - expired/reused QR、MITM、wrong host fingerprint、stolen device
  - replay、reorder、duplicate、counter rollback、clock skew、key rotation
  - relay disconnect、offline ciphertext expiry、duplicate APNs wake
  - 64 KiB terminal frameと10 MiB/s sustained stream

## Method

1. Threat modelをasset、actor、entry point、trust boundary、abuse caseごとにreviewする。
2. 候補libraryのmaintenance、security audit、license、constant-time claim、Mac/iOS/Rust support、test vectorを確認する。
3. Mac hostとiOS test clientでcross-language handshakeを実装し、host/device authenticationとderived key一致をofficial vectorで検証する。
4. Relay test doubleをmaliciousにし、frame capture、modify、drop、replay、route swap、delayを注入する。
5. Device revoke/rotation後にold connectionとoffline ciphertextを拒否できることを検証する。
6. Keychain/Secure Enclaveへ保存できるkey typeとexport制約を確認し、unsupported hardware fallbackを定義する。
7. Handshake latency、per-frame overhead、CPU、battery、memoryをLAN/mobile networkで測る。
8. Independent reviewerがprotocol composition、nonce/counter、error、log、backup/recoveryを確認する。

## Evidence

Not collected. Test vector、interop result、threat model、dependency/license report、benchmarkをrepositoryへ保存してlinkする。Private key、QR secret、real terminal contentをfixtureへ含めない。

## Results

Pending.

## Analysis

Pending.

## Recommendation

Pending. Security reviewが完了するまではprivate-network read-only canaryに限定し、internet relay上のterminal write、approval、terminateをreleaseしない。

## Limitations

- Secure Enclaveはすべてのkey algorithmを直接保持できるわけではない。Marketing上の名称ではなく選定algorithmとの実互換を検証する。
- E2EEはrelayが観測するIP、timing、packet size、presenceを隠さない。
- Biometric user presenceはOSが返す認証結果を使い、生体dataをprotocolへ含めない。
- Crypto libraryの安全性だけでは、authorization scope、UI spoofing、approval confused-deputyを解決しない。
