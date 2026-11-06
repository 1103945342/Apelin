# The agent's system prompt

Each file here is one section of the system prompt the agent reads, in
English. Edit the text here, never in Swift; then run

    Packages/ApelinAgent/Scripts/embed-prompts.py

which writes `Sources/ApelinAgent/Session/SystemPromptText.swift`, and commit
both. `make check` fails when the two differ. The text is compiled in rather
than shipped as a resource: a resource bundle's accessor would carry the build
machine's path into the binary.

- `NN-name.md`: `NN` orders the files, `name` becomes the Swift member
  (`20-working.md` → `SystemPromptText.working`).
- The first line is a `<!-- ... -->` comment saying what the section is and
  when a session gets it. It is left out of the prompt.
- `{{UPPER_SNAKE}}` is a value filled in when the prompt is made; a file with
  one becomes a function taking it (`{{PROJECT_ROOT}}` → `projectRoot:`).
- `SystemPrompt.make` decides which sections a session gets and puts them in
  order. A new file needs a line there; a renamed placeholder needs its call
  changed.

What is not here stays in Swift because it is made from facts, not written:
`# Environment` (`EnvironmentPrompt`, the device, toolchains and SDKs), the
MCP servers list and the skills list.

The prompt is cached by the provider: the same inputs must give the same
bytes, so nothing here may name a time, a count that changes or the approval
mode on now (that is `<system-state>`, on each message).
