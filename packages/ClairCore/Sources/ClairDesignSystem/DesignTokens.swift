/// Namespace for the Clair design tokens ported from the Design canvas.
///
/// Every value under `DesignTokens` is transcribed, not chosen, from
/// `docs/plans/clair-ui-implementation-checklist.md` §2 ("Design
/// tokens"), which is itself a frozen machine-copy of
/// `prototypes/clair-workbench/src/tokens.ts`. Do not add a token here that
/// the checklist does not define, and do not reach for a `native` alternative
/// (e.g. a system color) in place of a value the checklist gives explicitly.
///
/// Color tokens live under `DesignTokens.Color` / `.Line` / `.Wash` /
/// `.GroupColor`. Type scale, spacing/radius and motion primitives are
/// exposed as their own top-level namespaces (`Typography`, `Spacing`,
/// `Radius`, `ChromeBudget`, `MobileMetrics`, `Motion`) so downstream call
/// sites read `Typography.title`, `Spacing.scale`, `Motion.screenDuration`
/// rather than reaching through an extra `DesignTokens.` prefix.
public enum DesignTokens {}
