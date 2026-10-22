# Rayfall LSP

An editor-independent semantic analyzer and language server for Rayfall,
written in OCaml. This is an early working prototype, released under MIT.
It analyzes source without executing your program or starting Rayforce.

## What works

- Go to definition for parameters, local bindings, and sequential global
  bindings within the current document, including unsaved changes.
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

Cross-file loading, runtime inspection, completion, references, and rename
are not implemented yet. Query column resolution and dynamic evaluation
remain runtime-dependent. See [the design and roadmap](docs/design.md).

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
literal data, incomplete syntax, UTF-16 positions, and a real stdio LSP
session with unsaved edits. See [CONTRIBUTING.md](CONTRIBUTING.md).

Tree-sitter and the Rayfall grammar are pinned Git submodules. Neither
requires local patches. If a dependency needs changes, use a publicly
fetchable fork and publish its commit before updating the submodule pin.
Dependency licenses remain in their respective submodules.
