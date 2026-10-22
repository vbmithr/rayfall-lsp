# Contributing

Include a small Rayfall example, expected definition or uncertainty, and
actual behavior when reporting navigation issues. Mention the Rayforce
version if its runtime semantics are involved.

Run `dune fmt`, `dune build @all`, and `dune runtest` before submitting.
Keep behavior changes and their documentation together. Prefer semantic
fixtures over tests tied to implementation details. The Python integration
test exercises the executable through standard LSP framing.

Do not execute project source to improve static navigation. Preserve explicit
ambiguity when runtime behavior is unknown. New editor features should use
the shared analyzer rather than duplicate its scope rules.

Use public Git submodules for dependencies that require amendments. Publish
fork changes before updating a submodule pointer, preserve upstream licenses,
and describe the reason for each patch.
