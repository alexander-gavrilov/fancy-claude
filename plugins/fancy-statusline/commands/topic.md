---
description: Pin, reset, or hide the session topic shown in the status bar
argument-hint: [text | off]
allowed-tools: Bash(bash:*)
---

Run this exact command and report its output to the user verbatim, in one line:

!`bash "${CLAUDE_PLUGIN_ROOT}/hooks/topic-set.sh" $ARGUMENTS`

- With text, the topic is pinned and the automatic summarizer stops touching it.
- With no argument, the pin is dropped and the topic goes back to being derived automatically.
- With `off`, the topic line is hidden for the rest of this session.

Do not add commentary beyond the command's own output.
