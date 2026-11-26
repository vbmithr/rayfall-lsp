# Builtins

Hover on a name the document does not bind asks the Rayforce engine about it with `(.repl.signature 'name)`. That evaluates and calls nothing, and only a validated plain name is sent, never project code.

The hover shows the engine's one-line `summary`, how the builtin treats vector arguments, and its documented call forms, preceded by a note when the name is an alias or a special form:

```
Addition
atomic
(+ <left: num, date, time, timestamp or timespan> <right: the same kinds>)
```

The vector line comes from the engine's `atomic`, `aggregate` and `elementwise` fields: `atomic` (maps over vectors and lists in every argument), `aggregate` (reduces a vector), `element-wise` (every argument maps a vector element by element), or `element-wise in argument 2`. It is omitted when the engine describes none of these. `elementwise` describes one form of a builtin with several, such as `min`, so read it with the usage line.

A builtin with nothing documented shows only its calling convention, for example `name: builtin (vary)`. The server adds no help text of its own: the text is the engine's. Relevant engine issues: undocumented builtins ([#1736](https://github.com/RayforceDB/rayforce/issues/1736)), the `summary` field ([#1737](https://github.com/RayforceDB/rayforce/issues/1737)), and the atomicity fields ([#1744](https://github.com/RayforceDB/rayforce/issues/1744), [#1751](https://github.com/RayforceDB/rayforce/issues/1751)).

## Behaviour

- `rayforce` is run once per distinct name (a few milliseconds) and the answer is cached, negative ones included. Set `RAYFALL_ENGINE` to use another command; the default is `rayforce` on `PATH`.
- A name the document assigns keeps its own definition: the engine is asked only about names nothing in the document binds.
- A missing, slow or older engine falls back to the static description, silently.
- When the analysis cannot tell whether a call rebinds names, hover keeps the specific runtime-dependent caveat next to the builtin.
- Go to definition on a builtin finds nothing, because a builtin has no source. In Emacs the definition key then shows this hover instead.
