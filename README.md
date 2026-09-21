# QuickMarkview

QuickMarkview is a macOS Markdown viewer for the Neovim + WezTerm + coding-agent (Codex or Claude Code) workflow. It renders Markdown and Mermaid locally, follows external saves (including atomic rename saves), opens at a source line, and maps a selection in the rendered document back to source line numbers.

The viewer loads the official `markdown-it@14.1.0` and `mermaid@11.12.1` distribution bundles from app resources. No network request is made while viewing a document: remote images are blocked. The WebKit page is loaded once; subsequent saves replace its DOM through a JavaScript bridge and preserve the current scroll position. Mermaid layout is awaited before the initial line jump.

## Build and run

The target requires macOS 13 or newer and Xcode 26's Swift toolchain.

```sh
swift build -c release
.build/arm64-apple-macosx/release/QuickMarkview --line 42 path/to/note.md
```

For a Finder-launchable application bundle, run `scripts/build-app.sh`; it creates `dist/QuickMarkview.app`. The bundle script copies the SwiftPM resource bundle beside the executable, so the app does not depend on the repository working directory.

The command line options are:

```text
--line N          Scroll to one-based source line N.
--pane ID         Originating Neovim/WezTerm pane. Defaults to WEZTERM_PANE.
--target-pane ID  Explicit target when the tab has two coding-agent panes.
path              Markdown file to open. With no path, the Open button is shown.
```

The originating pane must be the leftmost pane in its current WezTerm tab. QuickMarkview calls `wezterm cli list --format json`, keeps only panes in that tab to the right of the origin, and accepts at most two. If two targets exist, choose one in the target menu before sending. The Send button performs the same lookup again immediately before sending. It sends the reviewed prompt as stdin to `send-text`, waits 50 ms, then submits a literal carriage return with `--no-paste`. A prompt starting with `/btw` first types `/btw ` with `--no-paste` and pastes only the rest, because Claude Code does not run a slash command that arrives inside a paste.

## Neovim example

Copy or adapt `nvim/lua/quickmarkview.lua` into your configuration:

```lua
local quickmarkview = require("quickmarkview")
vim.keymap.set("n", "<leader>am", quickmarkview.open, { desc = "Open Markdown in QuickMarkview" })
```

The example passes the current buffer, cursor line, and `WEZTERM_PANE` explicitly. It uses `open -n -a` to launch a fresh app instance and does not interpolate the path into a shell command. Set `quickmarkview.app` to an absolute app path if the bundle is not installed in `/Applications`.

Press `q` in the viewer to close it. `q` is typed normally while the request field or review panel has focus.

## Selection and sending

Drag across rendered text. The viewer reports the nearest Markdown block source range and the selected rendered text. The editable review panel builds the same prompt shape as the existing Neovim integration, including `/btw` side chat requests (supported by both Codex and Claude Code), and includes the source file, line range, and `<selection>` tags. Type the request in the toolbar field or directly in the review panel; Send is enabled once a selection, a target pane, and a non-empty prompt exist. Editing the prompt is local until Send is pressed. A file reload clears the selection and review text, and a revision check prevents a stale WebKit selection from being sent after a reload.

Links are rendered with HTML disabled. Only `http`, `https`, and `mailto` links explicitly clicked by the user are opened externally; arbitrary WebKit file navigation is rejected. Markdown images are limited to safe URL schemes by markdown-it's renderer policy.

The current viewer does not resolve relative image paths against the opened Markdown file, so document images should be considered unsupported. Remote images are replaced with a local placeholder and never fetched.

## Development

```sh
swift test
```

The tests cover prompt formatting and `/btw`, source-range clamping, pane ordering/target validation, pane ID zero, CLI parsing, JSON decoding, in-place watcher events, and atomic replacement saves. They never call the real WezTerm CLI or send a prompt.

Third-party notices and licenses are listed in `THIRD_PARTY_NOTICES.md`.
