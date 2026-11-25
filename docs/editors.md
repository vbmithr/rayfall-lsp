# Editors

Run `rayfall-lsp --stdio` as the language server for Rayfall buffers. It speaks standard LSP over stdin/stdout with full-document synchronization; use language ID `rayfall`.

## Emacs

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
Company idle delay. `M-TAB` can always request completion explicitly.

Other LSP clients can use the advertised `.` and quote triggers.

Ensure `rayfall-lsp` is on Emacs's `exec-path`. Use `M-.` for definitions, `M-?` for references; hover is available through Eglot/ElDoc.
