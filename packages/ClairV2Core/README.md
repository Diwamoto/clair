# Clair v2 core packages

This package is the dependency root for the native rewrite foundation. Each
target is a deliberately small, independently buildable boundary for a v2
component. The targets contain no v1 application or mobile-control module.

The package currently provides only identity markers and dependency wiring.
Protocol models, daemon lifecycle, pairing, editor behavior, and UI belong to
later queue items.
