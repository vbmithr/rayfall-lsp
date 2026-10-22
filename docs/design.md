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
follows literal-load dependencies for cross-file binding navigation. Each
request builds a fresh bounded dependency snapshot; open buffers override
disk sources. Relative paths are searched from the importer up to its nearest
workspace root, retaining all existing matches as candidates. Cycles terminate
by canonical file identity. Input size and analysis nesting are bounded;
syntax errors produce diagnostics and conservative results.

Sequential bindings and lexical parameters can have precise targets.
References to globals inside functions are deferred: their meaning can
change before a call. These produce candidate definitions, with an explicit
explanation. Conditional arms are analyzed separately with their lexical scope intact.
Unknown calls and loads affect global certainty, not recognition of later
core forms. This assumes standard core forms unless explicitly shadowed;
dynamic rebinding of core forms is not modeled. Other unsupported control
flow and dynamic operations produce runtime-dependent results instead of
invented certainty.

Literal query dictionaries have a separate expression context. Their source
expression uses the surrounding scope; row expressions preserve lexical
locals and parameters. Bare names without a lexical binding remain possible
columns, even when an unrelated global exists. Qualified globals are candidate
assignments with an explicit column-shadowing caveat. Nested queries and
inline lambdas retain captures; query keys and output aliases are not lexical
references. Literal table headers and query output labels have distinct
column identities. Schemas flow through local aliases, sorting, projections,
and ungrouped updates. Loaded global table declarations are schema hints;
call-time mutation keeps their origins uncertain. After collecting the bounded
load graph, the current document is analyzed again with these hints so imported
headers and local query aliases can supply navigation targets. Dependencies
are not iterated to a whole-project type-inference fixed point. Literal-key
left, inner, and full joins preserve known input column origins, and `ungroup`
preserves names across row flattening. Grouping key labels and non-key
passthrough columns survive those operations. Other join kinds, arbitrary
dynamic schemas, grouped update outputs, and control clauses remain future work.

Quoted symbols stay data except in recognized reference positions. The first
argument of the builtin `alter` names a mutation target; its operation argument
is unevaluated data. Explicit shadowing disables that special interpretation,
and lexical targets remain unsupported as in Rayforce.

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

The initial project model now follows literal loads without executing them,
uses workspace roots, and refreshes dependency snapshots after edits. It also
supports `.rayfall-lsp.json` entrypoint and working-directory settings:
configured runners contribute their literal dependencies, and an explicit
working directory disambiguates paths. Neither setting establishes actual
execution order. Next, model execution order where it is statically known;
dynamic paths and call-time global mutation must remain uncertain. Add cached
snapshots with dependency invalidation if profiling shows repeated parsing
is costly, preserving the fresh-snapshot behavior covered by tests.

Find references now uses declaration locations, names and kinds across the
bounded load graph. Definite and possible matches remain separate in the core
API; standard LSP exposes definite matches and rejects ambiguous targets.
This is not an exhaustive workspace index and is not sufficient for rename.

Next, extend reference coverage and add completion using those identities.
Inferring table schemas for function parameters is also still missing: a
query over an unannotated parameter cannot trace its columns back to callers.
Rename should wait until incomplete and ambiguous reference sets can be
reported and unsafe edits refused.

Finally, consider an opt-in Rayforce protocol for live values, definition
identities, and source locations. Runtime observations must identify their
session and source revision so stale values cannot silently override editor
analysis. This requires engine support and is not part of the prototype.

## Dependency policy

Dependencies requiring amendments belong in Git submodules pointing to
public commits, using a fork under `vbmithr` when upstream changes are needed.
Keep modifications reviewable and submit generally useful changes upstream.
Avoid dependencies on private configuration or one editor's runtime.
