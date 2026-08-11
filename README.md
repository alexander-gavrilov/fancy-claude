# fancy-claude

A personal Claude Code plugin marketplace by Alexander Gavrilov.

## Plugins

| Plugin | Description |
|---|---|
| [fancy-statusline](plugins/fancy-statusline/) | Rich 6-line status bar leading with an auto-derived session topic (`FANCY_STATUSLINE_TOPIC=off` to disable), plus model, context, MCP, and rate limit info |

## Add this marketplace

```bash
claude plugin marketplace add alexander-gavrilov/fancy-claude
```

Then install individual plugins:

```bash
claude plugin install fancy-statusline@fancy-claude
```
