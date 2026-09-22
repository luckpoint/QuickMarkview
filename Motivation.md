# Motivation

This is the original request that started QuickMarkview.

---

I want a simple Markdown viewer, written in Swift.

- It does not need editing.
- It should render the file again after it is edited.
- It should support Mermaid (mermaid.js).
- Please focus on performance.

## Why

I want it to work with Codex running in WezTerm.

```text
| Neovim | Codex |
```

Codex runs in a pane on the right third of WezTerm. Neovim usually runs in the left pane.

I can already send text selected in Neovim to Codex in WezTerm. But I also want to select text in the rendered document and send that to Codex.

When I open the viewer from Neovim, it should open at the same cursor position as Neovim (the line is enough).

## Reference: the existing Neovim plugin

The Neovim plugin should be a good reference.

### wezterm_agent: send from Neovim to the Codex pane (the core)

It is loaded by calling `require("wezterm_agent").setup()` directly. It is a side-effect load, not a lazy.nvim spec.

Flow:

```text
Visual selection, then <leader>aa or :WeztermAgentSend
  → get_visual_range()      … uses getregion() if available; older versions fall back to whole lines
  → build_agent_prompt()    … builds the File / Lines / Request / <selection> payload
  → floating payload editor (a scratch buffer; the original file is not changed)
  → <S-CR>
  → wezterm cli list --format json  … finds its own pane from WEZTERM_PANE
  → find_target_panes()     … panes in the same tab, sorted by left_col; stops if Neovim is not the leftmost
  → wezterm cli send-text --pane-id N   (payload on stdin)
  → after 50 ms, send-text --no-paste "\r"   (the newline submits it)
```

Key points:

- Pane roles: the leftmost pane (Neovim) is fixed, and up to two panes to its right are targets (`max_targets = 2`). With two panes, they are Pane1 and Pane2.
- Codex only: if the first line is `/btw`, the payload is sent as a side chat (`extract_side_chat_request`). Other agents do not have this branch.
- History: only the prompt text is saved, as JSON. `<C-r>`/`<C-y>` pick one with Telescope (or fall back to `vim.ui.select` if Telescope is not installed).
- Sending takes two steps: paste, wait, then `\r` with `--no-paste`. This works around the TUI's bracketed paste swallowing the newline.

First, tell me what you understood so I can check it.
