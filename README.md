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

Runtime inspection, completion, references, and rename are not implemented
yet. Query column resolution and dynamic evaluation remain runtime-dependent.
See [the design and roadmap](docs/design.md).

## Cross-file navigation

For `(load "helpers.rfl")`, the server follows literal paths without running
Rayfall. Relative paths are tried from the importing file's directory and
each ancestor up to the nearest containing LSP workspace root. Without a
workspace root, only the importing directory is searched. Absolute paths
are supported. If several paths exist, all remain candidates.

This also handles a strategy loading `strategies/common.rfl` while stored
inside `strategies/`: the path can resolve from its parent directory.
Only files reachable through recognized literal loads are included; unrelated
workspace files and runtime session globals are not searched.

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

Cross-file function-value origin tracking and exact load-order modeling are
still future work; this milestone adds binding navigation.

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
