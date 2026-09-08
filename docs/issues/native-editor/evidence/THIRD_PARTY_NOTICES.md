# Native editor PoC third-party notices (draft)

This is a draft inventory for the NE-00 native editor PoC. It is not a
distribution approval and must not be shipped as a substitute for the missing
CodeEditLanguages, grammar, or CodeEditSymbols provenance. The audit and the
fixed revisions are in [license-audit.md](license-audit.md).

## Notice inventory

The following license files were found at the fixed SwiftPM revisions. The
final distributed app must include the complete license text, not only a URL.
The SHA-256 values are retained in `prototypes/native-editor-poc/evidence/dependencies.json`
and the audit so that a later generated notice can be checked against the
source checkout.

| component | license | fixed license file |
|---|---|---|
| CodeEditSourceEditor | MIT | `LICENSE.md` (`a1c7f7ef...`) |
| CodeEditTextView | MIT | `LICENSE.md` (`960d8436...`) |
| Rearrange | BSD-3-Clause | `LICENSE` (`72512faf...`) |
| swift-collections | Apache-2.0 | `LICENSE.txt` (`770af829...`) |
| SwiftLintPlugin | MIT | `LICENSE` (`27075ecb...`) |
| SwiftTreeSitter | BSD-3-Clause | `LICENSE` (`792197b8...`) |
| TextFormation | BSD-3-Clause | `LICENSE` (`d11b5eea...`) |
| TextStory | BSD-3-Clause | `LICENSE` (`afbec25c...`) |
| tree-sitter runtime | MIT | `LICENSE` (`5f9cf9fb...`) |
| tree-sitter Unicode subset | Unicode/ICU terms | `lib/src/unicode/LICENSE` (`6a18c5fa...`) |
| tree-sitter-swift grammar | MIT | grammar `LICENSE` (`3533cec1...`) |

The complete license texts are intentionally not copied from an untracked
SwiftPM cache into this draft. Before any app distribution, generate a tracked
notice artifact from the exact checkout and fail the build if a listed hash or
license file is missing.

## Distribution blockers

- `CodeEditLanguages` (`331d5dbc5fc8513be5848fce8a2a312908f36a11`) has no root
  LICENSE/NOTICE in the audited checkout. Its `CodeLanguagesContainer.xcframework.zip`
  is a binary containing all 37 grammar parsers, while the audit has no
  grammar-by-grammar notice bundle.
- `CodeEditSymbols` (`ae69712b08571c4469c2ed5cd38ad9f19439793e`) has no root
  LICENSE/NOTICE. Its 33 asset-catalog files are described as mostly custom SF
  Symbols, but per-asset provenance and Apple-use constraints are not recorded.
- The six PoC languages (Swift, Rust, TypeScript, TSX, JSON, Markdown) have
  fixed query hashes, but query-to-parser binary correspondence and source
  license evidence are incomplete except for the Swift grammar checkout noted
  above.

**Status: NOT CLEARED FOR DISTRIBUTION.** Keep the native editor opt-in and do
not change the normal editor or package the PoC until the audit blockers are
resolved.
