# Rayfall LSP

An editor-independent semantic analyzer and language server for Rayfall,
written in OCaml. This is an early working prototype, released under MIT.
It analyzes source without executing your program or starting Rayforce.

## What works

- Go to definition for parameters, local bindings, and sequential global
  bindings, including unsaved changes.
- Cross-file candidate definitions through literal `load` dependencies,
  including transitive loads and unsaved dependency buffers.
- Hover explanations distinguishing known bindings, candidate definitions,
  runtime-dependent names, and unresolved names.
- Tracking function values through direct aliases, exposed through the
  experimental `rayfall/followValue` request.
- Dotted-name navigation: on `bt` in `bt.cash0`, find the namespace binding;
  on `cash0`, find known assignments to that qualified field. This also
  applies to assignment targets: in `(set bt.cash0 ...)`, `bt` is a namespace
  reference and `cash0` is the field declaration, which resolves to itself.
  A lexical parameter named `bt` takes precedence over an unrelated global
  namespace.
- Parameters and locals inside `select`, `update`, and `delete` expressions,
  plus candidate definitions for qualified globals inside queries.
- Syntax diagnostics, incomplete source, and UTF-16 editor positions.

Function bodies can run after globals change. Global references inside them
therefore return candidate definitions rather than claiming a unique target.
Unknown calls and dynamic forms also make subsequent global resolution
conservative. They do not erase lexical parameters or stop recognition of
later core forms such as `fn` and `let`. Core forms are assumed to retain
their standard meaning unless explicitly shadowed in the document; dynamic
rebinding of core forms is not modeled. Conditional arms retain lexical
scope, but their global writes are not assumed to execute. Quoted data is
not treated as executable references.

Runtime inspection and rename are not implemented yet. Field completion
uses known static shapes. Dynamic schemas and evaluation remain runtime-dependent.
See [the design and roadmap](docs/design.md).

## Structure hover

Hover a binding, reference, or literal to inspect known dictionary keys and
table columns alongside its existing binding information. Ordinary go to
definition still jumps to the binding or column declaration. In Emacs,
the optional on-demand setup below displays details near point with `C-c C-d`,
without automatic hover requests while moving the cursor.

Dictionary literals and `(dict [keys] values)` with literal symbol keys expose
their known keys without evaluating dictionary contents. Aliases retain that
shape. Known table constructors and query outputs expose columns, including
table-parameter hints from observed callers. Global namespace fields such as
`bt.cash0` also contribute candidate members when hovering `bt`.

Hover distinguishes known, partial, and candidate shapes. It displays up to
64 fields and counts additional known fields; stored summaries retain up to
256 names. Shapes reflect static evidence, not live object inspection or a
complete runtime schema. Dictionary parameter/return shapes, nested field
value types, vector/list element types and lengths, and function signatures
are not inferred by this first hover version.

## Find references

Use `M-?` (`xref-find-references`) in an Eglot-managed buffer. The server
implements `textDocument/references`, including `includeDeclaration`.
References match declaration locations, names, and binding kinds, so lexical
shadowing and unrelated same-name declarations in other files stay separate.
Known column aliases use the same identities as definition navigation.

Results include definite matches in the current bounded load graph.
Candidate globals, uncertain imported column origins, unknown callers, and
dynamic references are not promoted to definite matches. Invoking the command
on an ambiguous or runtime-dependent use reports that limitation; selecting
a declaration searches its definite matches. The server logs the number of
excluded possible matches. Eglot includes the declaration in its results.

This is not an exhaustive whole-workspace index or a safe rename operation.
The core API returns definite and possible locations separately, but the
standard LSP command exposes only definite locations. Unsaved sources are
used throughout the search.

## Query navigation

For a literal query dictionary, `from:` is analyzed in the surrounding
scope. Predicates, projections, update expressions, and dictionary-form
`by:` expressions retain lexical parameters, locals, and captures. For
example, in `(select {from: t where: (> price cutoff)})`, a parameter named
`cutoff` resolves to its declaration. Output labels define columns rather than
lexical variables; control keys remain data. Nested queries and inline lambdas
preserve lexical bindings.

Rayforce lets lexical locals shadow columns; columns can shadow globals.
Without a known source schema, a bare name such as `price` therefore stays
runtime-dependent rather than jumping to an unrelated global. Qualified
names such as `bt.cash0` offer known namespace and field assignments as
candidates, with hover explaining that a column could shadow the namespace.
A lexical namespace parameter still takes precedence.

Literal `(table [price qty] ...)` headers define column origins. Known schemas
follow local aliases, `xasc`/`xdesc`, `ungroup`, projections, and ungrouped
updates. A query
reading `price` can jump to its header. A later query reading a calculated
alias such as `notional: (* price qty)` can jump to that output label, whose
expression in turn links to the source columns. Dictionary-form grouping
labels also define output columns. Bare-name and literal-vector grouping keys
preserve output names; a grouped passthrough retains non-key columns too.
Literal grouping vectors refer to source columns, while bare expressions keep
lexical lookup precedence.

With literal key vectors and known input schemas, `left-join`, `inner-join`,
and `full-join` carry column origins from both inputs. Both argument orders
are supported. Non-key name collisions use the left origin, matching ordinary
Rayforce named lookup. Left/inner output keys retain the left origin; full
join keys can originate from either input. The key vector itself refers to
both inputs. Unknown schemas and dynamic join keys remain conservative.

Loaded literal table declarations enrich the current document's analysis.
Global table assignments, including alternative assignments, contribute
candidate column origins rather than guaranteed runtime schemas. Unsaved
dependency edits refresh those origins. This is bounded structural inference,
not execution or a complete type checker: arbitrary cross-file computations,
other join kinds, dynamic constructors, unobserved or higher-order call schemas,
grouped update results, sorting/control clauses,
and quoted in-place update/delete targets remain unsupported.

Function parameters can receive schema hints from visible call sites, including
calls across loaded files. Function return summaries let a table produced by
one helper supply a later helper's argument schema. For example, if a runner
passes `(make_table)` into a reporting helper, column navigation in that helper
can trace back to `make_table`'s known outputs. Simple aliases keep the origin
of the function they captured even after its original name is reassigned.

These are candidate origins, not parameter types or a closed-world guarantee.
Unknown callers and arguments may differ. Conflicting observed schemas retain
all known origins. The analysis uses two project-wide summary passes followed
by a current-document pass, so deep chains, recursion and higher-order calls
may remain unresolved. Each document records at most 4096 call-target records
and 64 arguments per record, with up to 16 global function origins per name;
imported argument hints are capped at 16384 observations per analysis. Nothing
executes project code. Unsaved caller edits refresh the hints.

Quoted symbols normally remain data. The first argument to the builtin
`alter` is an exception: `(alter 'bt.qty set i value)` references a mutation
target, so `bt` and `qty` support definition navigation there. The unevaluated
operation name and ordinary quoted symbols remain data. Lexical alter targets
are marked unsupported, matching Rayforce's restriction on local mutation.
A shadowed function named `alter` keeps ordinary function-call semantics.

Dynamically constructed query dictionaries remain opaque. Ordinary
dictionaries and vectors keep their literal-data semantics outside recognized
constructors and query clauses. Query output aliases do not become lexical
bindings outside the query.

## Cross-file navigation

For `(load "helpers.rfl")`, the server follows literal paths without running
Rayfall. Relative paths are tried from the importing file's directory and
each ancestor up to the nearest containing LSP workspace root. Without a
workspace root, only the importing directory is searched. Absolute paths
are supported. If several paths exist, all remain candidates.

This also handles a strategy loading `strategies/common.rfl` while stored
inside `strategies/`: the path can resolve from its parent directory.
Only the current document, configured entrypoints, and their recognized
literal-load dependencies are included; unrelated workspace files and runtime
session globals are not searched.

Imported assignments are candidate definitions, not a claim about which
assignment ran last. Go to definition may return several locations, and hover
explains the uncertainty. Dynamic load paths, missing files, and analysis
limits appear in hover information. Unsupported control flow may hide loads.
Core-form shadowing is respected; an ordinary function named `load` is not
followed as a dependency.

Open editor documents override disk content, including unsaved files. Each
navigation request builds a fresh bounded dependency snapshot, so dependency
edits, closes, and disk changes do not leave stale targets. Analysis currently
allows 128 files, 32 load edges in depth, and 16 MiB of source per request,
with a 4 MiB limit per file. Only regular files are read. Large dependency
graphs may return a partial set of candidates, with a hover explanation.

### Entrypoints and working directory

For programs whose runner loads the kernel and selects a plugin dynamically,
put `.rayfall-lsp.json` in the project directory:

```json
{
  "entrypoints": ["run.rfl"],
  "workingDirectory": "."
}
```

The nearest configuration between the current file and its containing
workspace root applies. Both fields are optional; paths are relative to the
configuration file, and absolute paths are also accepted. Configuration is
checked for changes on each request. Invalid configuration is explained in hover and
does not disable ordinary literal-load navigation.

`entrypoints` adds the listed runners and their literal dependencies to the
current document's dependency snapshot. This makes a kernel loaded by
`run.rfl` visible from a strategy even when the runner chooses that strategy
through a dynamic path. Up to 16 entrypoints may be listed. Their order does
not imply execution order; multiple runners contribute alternative candidates.

`workingDirectory` resolves every relative load against that directory,
replacing the ancestor search. Use it to match the directory from which you
run Rayforce and eliminate ambiguous path matches. Unsaved entrypoint buffers
override their disk versions, just like other dependencies.

Configuration never executes code or interprets dynamic paths. Global
references inside a function still depend on call time, so entrypoint
assignments remain candidates. Entrypoints establish possible shared context,
not proof that a dynamically selected strategy or an assignment executed.
Cross-file function-value origin tracking and exact execution-order modeling
remain future work.

## Build and test

You need OCaml 4.14 or newer, opam, a C compiler, Git, and Python 3 for the
integration test. Start in an initialized opam switch, then run:

```sh
git clone --recurse-submodules https://github.com/vbmithr/rayfall-lsp.git
cd rayfall-lsp
opam install . --deps-only --with-test
eval $(opam env)
dune build @all
dune runtest
dune install
```

For an existing checkout, fetch pinned dependencies with
`git submodule update --init --recursive`. Build from a recursive Git
checkout; this project is not published in the opam package repository yet.

## Editors

Run `rayfall-lsp --stdio` as the language server for Rayfall buffers. The
server uses standard LSP over stdin/stdout and full-document synchronization.
Its core library is separate from the server executable.

With an existing Emacs `rayfall-mode` and Eglot:

```elisp
(require 'eglot)
(add-to-list 'eglot-server-programs
             '(rayfall-mode . ("rayfall-lsp" "--stdio")))
(add-hook 'rayfall-mode-hook #'eglot-ensure)
```

For manual inspection and automatic completion, load the optional helper after Eglot:

```elisp
(load "~/code/rayfall-lsp/editors/emacs/rayfall-lsp-ui.el")
```

It disables automatic ElDoc requests in Eglot-managed Rayfall buffers and
configures Company to offer completion after two characters and a 0.2-second
typing pause. Press `C-c C-d` to request semantic details in
a read-only popup using `posframe` and Company tooltip colors. The popup is
limited to 90 columns and 18 lines and disappears on the next command.
It is inspection, so selecting text cannot insert it as a completion.
Use `C-u C-c C-d` for a help window containing the full details. Without
`posframe` or a graphical display, inspection falls back to that help window.
Replies received after moving point or editing the buffer are discarded.
Typing `.` starts a Company field-completion menu automatically. It does not
insert a candidate until you accept one. Ordinary prefixes such as `(tabl`
also open the menu after the short typing pause; global name suggestions need
an already-running Rayfall session (`M-x rayfall-repl`).
`M-TAB` opens the menu without inserting text, including with one remaining
candidate. It works after moving point into existing code, including
inside `(at cfg 'ca)` after the quoted key prefix. Company must be enabled.
Other modes retain their existing settings.

When the existing Rayfall REPL is running and idle, the Emacs helper also
queries `(.repl.complete "prefix")` for global names and leading-dot builtin
namespaces. For example, `ta` can offer `table`, `take`, and `tan`; `.repl.`
can offer the engine's actual registered verbs. These candidates carry a
`[Rayforce session]` annotation and take precedence over static fallback.
It waits at most 150 ms (`rayfall-lsp-live-completion-timeout`), skips busy
sessions, and falls through to Eglot on errors or no results. Disable it with
`rayfall-lsp-live-completion` set to nil. It uses the already-running REPL;
the helper replaces the old completion fallback that could start a REPL.
No project source is loaded or evaluated for a completion request.

This is an Emacs bridge alongside the LSP, not a runtime connection inside
the standalone server. `.repl.complete` currently lists namespace names, not
dictionary keys, so ordinary member access such as `bt.` and quoted keys
continue to use static LSP hints. Runtime value inspection is proposed in
[Rayforce #945](https://github.com/RayforceDB/rayforce/issues/945).

The server implements standard LSP field completion for dotted receivers
such as `bt.` and literal quoted keys of builtin `at`. It reuses dictionary,
namespace, and table shapes already available to hover, preserving candidate
labels for uncertain shapes. Suggestions replace only the field token and
respect lexical shadowing. Incomplete assignment targets such as `(set bt.)`
retain the receiver shape without declaring a new binding. Comments, strings,
quoted data, unknown receivers,
and shadowed `at` calls do not borrow fields from unrelated global values.
Dictionary callback parameter inference and nested dictionary value types
remain unsupported: a callback parameter such as `ctx` may have no fields.
The dot trigger opens the menu immediately, while other prefixes use the
Company idle delay. `M-TAB` can always request completion explicitly. Other LSP clients can use the advertised `.` and quote triggers.

Ensure `rayfall-lsp` is on Emacs's `exec-path`. Use `M-.` for definitions;
hover information is available through Eglot/ElDoc. Other LSP clients can
launch the same command with language ID `rayfall`.

## Development

```sh
opam install ocamlformat.0.29.0
dune fmt
dune build @all
dune runtest
```

Tests cover binding and value origins, lexical shadowing, deferred globals,
literal data, incomplete syntax, UTF-16 positions, dependency cycles,
transitive loads, ambiguous targets, and live-buffer overlays. Real stdio LSP
sessions exercise unsaved edits and cross-file target ranges. See [CONTRIBUTING.md](CONTRIBUTING.md).

Tree-sitter and the Rayfall grammar are pinned Git submodules. Neither
requires local patches. If a dependency needs changes, use a publicly
fetchable fork and publish its commit before updating the submodule pin.
Dependency licenses remain in their respective submodules.

## Request caching

The server retains up to four recent project snapshots. Repeated navigation
and hover requests reuse analysis when editor contents, workspace roots, and
observed filesystem paths are unchanged. Opening, changing, or closing an
editor document causes the next request to rebuild its project snapshot.
Dependencies, configuration candidates (including absent files), and load
candidates are checked using filesystem identity, size, modification time,
and change time. Reading a file does not invalidate the cache.

The first request after a change still performs the bounded project analysis;
this is snapshot caching, not incremental analysis. Filesystem checks rely on
normal filesystem metadata updates, rather than hashing file contents.
Reference searches still do additional analysis within the cached graph.

To measure real stdio definition requests on your project:

```sh
python3 bench/navigation.py --root /path/to/project \
  --file /path/to/project/report.rfl --symbol bt.ledger \
  /path/to/old/rayfall-lsp /path/to/new/rayfall-lsp
```

A local comparison on the backtester `report.rfl` (11 requests per process)
measured a repeated-request median of 63.39 ms before caching and 0.03 ms after
caching. First requests took 89.66 ms and 66.70 ms respectively. These are
single-run observations, not portable performance guarantees.
