# Semantic tooling design

## Goal

Provide useful semantic navigation to every Rayfall editor through a shared
OCaml analysis library and an LSP executable. A syntactic name match is not
enough: navigation should account for scope, reassignment, aliases, and
runtime uncertainty.

## Initial implementation

A pinned Tree-sitter parser produces a concrete syntax tree. A small C bridge
copies node kinds, byte ranges, and relationships into OCaml, then releases
the native tree. The analyzer creates bindings, references, and function
value origins from that snapshot. The LSP layer maps document versions and
UTF-16 positions to these results.

The server analyzes unsaved documents and never evaluates source. Analysis
currently stays within one document. Input size and analysis nesting are
bounded; syntax errors produce diagnostics and conservative results.

Sequential bindings and lexical parameters can have precise targets.
References to globals inside functions are deferred: their meaning can
change before a call. These produce candidate definitions, with an explicit
explanation. Conditional arms are analyzed separately with their lexical scope intact.
Unknown calls and loads affect global certainty, not recognition of later
core forms. This assumes standard core forms unless explicitly shadowed;
dynamic rebinding of core forms is not modeled. Other unsupported control
flow, queries, and dynamic operations produce runtime-dependent results
instead of invented certainty.

Binding navigation and value navigation are distinct. After assigning an
alias to a function, redefining the original binding does not change the
function already captured by that alias. The experimental
`rayfall/followValue` request takes the same text document and position
parameters as `textDocument/definition`, and returns a status plus source
locations for known function origins. It is not an advertised standard LSP
capability and has no editor command yet.

## Why OCaml

OCaml fits immutable syntax snapshots, explicit resolution states, and
scope analysis. Existing JSON-RPC and LSP libraries handle protocol messages
and transport. Tree-sitter supplies error recovery and grammar reuse;
the native bridge stays small and separate from semantic rules.

The analyzer does not depend on Rayforce internals. Engine support should
be optional and introduced only where static analysis cannot answer safely.

## Next milestones

First, extend fixtures against real Rayforce semantics: special-form
shadowing, closure capture, namespaces, destructuring, and control flow.
Every new precise result should have a regression fixture; uncertain cases
must remain visibly uncertain.

Then introduce a project model with explicit roots and load paths. Index
files without executing them, track load order where it is statically
known, and invalidate dependent snapshots after edits. Cross-file navigation
must distinguish a known load target from a guessed filename match.

Next, add references and completion using the same binding identities.
Rename should wait until ambiguity and dynamic references can be reported
and unsafe edits refused.

Finally, consider an opt-in Rayforce protocol for live values, definition
identities, and source locations. Runtime observations must identify their
session and source revision so stale values cannot silently override editor
analysis. This requires engine support and is not part of the prototype.

## Dependency policy

Dependencies requiring amendments belong in Git submodules pointing to
public commits, using a fork under `vbmithr` when upstream changes are needed.
Keep modifications reviewable and submit generally useful changes upstream.
Avoid dependencies on private configuration or one editor's runtime.
