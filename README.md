# Rayfall LSP

A language server and semantic analyzer for [Rayfall](https://github.com/RayforceDB/rayforce),
written in OCaml. It works on source alone: it never runs your program. Early
prototype, MIT licensed.

## Features

- **Go to definition** for parameters, locals and globals, including unsaved
  buffers and literal `load` dependencies across files.
- **Find references** that keep shadowing and same-name declarations apart.
- **Hover** that says whether a name is known, a candidate, runtime-dependent
  or unresolved, shows dictionary keys and table columns, and, for builtins,
  what the Rayforce engine says about them.
- **Query and column navigation** inside `select`, `update` and `delete`,
  through aliases, joins and grouping.
- **Field completion** for `bt.` and quoted `at` keys.
- Syntax diagnostics and UTF-16 positions.

Where the answer depends on runtime (a global read inside a function, a
dynamic load) the server returns candidates and says so, rather than
guessing. Rename and runtime inspection are not implemented.

## Install

You need OCaml 4.14+, opam, a C compiler, Git, and Python 3 for the
integration test.

```sh
git clone --recurse-submodules https://github.com/vbmithr/rayfall-lsp.git
cd rayfall-lsp
opam install . --deps-only --with-test
eval $(opam env)
dune build @all && dune runtest && dune install
```

Not on the opam repository yet. In an existing checkout run
`git submodule update --init --recursive`.

## Use

Run `rayfall-lsp --stdio` as the server for Rayfall buffers (language ID
`rayfall`). With Emacs and Eglot:

```elisp
(add-to-list 'eglot-server-programs
             '(rayfall-mode . ("rayfall-lsp" "--stdio")))
(add-hook 'rayfall-mode-hook #'eglot-ensure)
```

Builtin hover needs `rayforce` on `PATH` (or `RAYFALL_ENGINE`) and degrades
silently without it. For a runner that picks its script dynamically, add a
`.rayfall-lsp.json`:

```json
{ "entrypoints": ["run.rfl"], "workingDirectory": "." }
```

## Documentation

- [Navigation, hover and references](docs/navigation.md): scope rules, queries,
  cross-file loads, entrypoint configuration, caching and limits
- [Builtins](docs/builtins.md): how hover uses the engine
- [Editors](docs/editors.md): Emacs helper, completion, other clients
- [Design and roadmap](docs/design.md)
- [Contributing](CONTRIBUTING.md): `dune fmt`, `dune build @all`, `dune runtest`

Tree-sitter and the Rayfall grammar are pinned Git submodules, used without
local patches.
