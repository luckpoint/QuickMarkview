![QuickMarkview](img/logo.png)

# QuickMarkview

QuickMarkview is a macOS Markdown viewer for the Neovim + WezTerm + coding-agent (Codex or Claude Code) workflow. It renders Markdown and Mermaid locally, follows external saves (including atomic rename saves), opens at a source line, and maps a selection in the rendered document back to source line numbers.

The viewer loads the official `markdown-it@14.1.0` and `mermaid@11.12.1` distribution bundles from app resources. No network request is made while viewing a document: remote images are blocked. The WebKit page is loaded once; subsequent saves replace its DOM through a JavaScript bridge and preserve the current scroll position. Mermaid layout is awaited before the initial line jump.

## Demo

https://github.com/user-attachments/assets/7da0fb62-7450-498b-a194-af7dd13b87ee

Demo: Split WezTerm window with Neovim on the left and Claude Code on the right.
1. Code Selection: The user visually selects a block of Swift code in Neovim.
2. Payload Generation: A modal generates a structured prompt containing the file path, line range, and selected code, where the user adds the request (Explain).
3. Inter-pane Transfer: The prompt is sent directly into the Claude Code pane via WezTerm CLI.
4. Agent Execution: Claude Code receives the context, begins reasoning, and runs shell commands to analyze the codebase and explain the snippet.

## Build and Run

The target requires macOS 13 or newer and Xcode 26's Swift toolchain.

```sh
swift build -c release
.build/arm64-apple-macosx/release/QuickMarkview --line 42 path/to/note.md
```

For a Finder-launchable application bundle, run `scripts/build-app.sh`; it creates `dist/QuickMarkview.app`. The bundle script copies the SwiftPM resource bundle beside the executable, so the app does not depend on the repository working directory.

To install, run `scripts/install.sh`. It builds the bundle, moves it to `/Applications/QuickMarkview.app` (or `<dir>/QuickMarkview.app` with `scripts/install.sh <dir>`), and registers it with Launch Services so `open -a QuickMarkview` finds the installed copy. Run it again to update.

The command line options are:

```text
--line N          Scroll to one-based source line N.
--pane ID         Originating Neovim/WezTerm pane. Defaults to WEZTERM_PANE.
--target-pane ID  Explicit target when the tab has two coding-agent panes.
--resident        Keep the app running when the viewer is closed or q is pressed.
path              Markdown file to open. With no path, the Open button is shown.
```

The originating pane must be the leftmost pane in its current WezTerm tab. QuickMarkview calls `wezterm cli list --format json`, keeps only panes in that tab to the right of the origin, and accepts at most two. If two targets exist, choose one in the target menu before sending. Shift+Enter performs the same lookup again immediately before sending. It sends the reviewed prompt as stdin to `send-text`, waits 50 ms, then submits a literal carriage return with `--no-paste`. A prompt starting with `/btw` first types `/btw ` with `--no-paste` and pastes only the rest, because Claude Code does not run a slash command that arrives inside a paste.

## Neovim example

Copy or adapt `nvim/lua/quickmarkview.lua` into your configuration:

```lua
local quickmarkview = require("quickmarkview")
vim.keymap.set("n", "<leader>am", quickmarkview.open, { desc = "Open Markdown in QuickMarkview" })
```

The example passes the current buffer, cursor line, and `WEZTERM_PANE` explicitly. By default it uses `open -n -a` to launch a fresh app instance. Set `quickmarkview.resident = true` to keep one app process and send each file through the `quickmarkview://` URL scheme. Set `quickmarkview.app` to an absolute app path if the bundle is not installed in `/Applications`.

The window opens over the left two thirds of the screen at full height. Press `q` in the viewer to close it. In resident mode, `q` and the close button hide the window; click its Dock icon to show it again. ⌘Q always quits. `q` is typed normally while the request panel has focus. The table-of-contents sidebar starts hidden; press ⌘L (View › Toggle Sidebar) to show or hide it. Press ⌘K (View › Go to Markdown File…) to find and open a Markdown file in the project.

## Selection and sending

The viewer has a Vim-style cursor:

```text
h j k l     Move by character / line.
e           Edit the Markdown source of the paragraph, heading, list item, or table cell under the cursor; Enter saves, Shift+Enter adds a line (paragraphs), Esc cancels.
J K         Move to the same column in the next / previous table row.
<Tab>       Move to the next table cell.
0 $         Line start / end.
gg G        Document start / end.
<C-f> <C-b> Scroll half a page down / up; the cursor moves with it.
v           Toggle visual selection; motions extend it. Esc leaves it.
V           Toggle linewise visual selection over whole rendered lines.
<Space>aa   Open the request panel for the current selection.
<C-]>       Open the local link under the cursor; clicking a local link also follows it.
<C-^>       Switch to the alternate file (press again to switch back).
```

Dragging with the mouse also selects. The viewer reports the nearest Markdown block source range and the selected rendered text. The request panel is a native text view prefilled with the full prompt in the same shape as the existing Neovim integration: source file, line range, an empty `Request:` section where the cursor starts, and the `<selection>` tags. Edit any part of it, then press Shift+Enter to send exactly that text, or Esc to cancel. Start the first line with `/btw` for a side chat request (supported by both Codex and Claude Code). A file reload clears the selection, and a revision check prevents a stale WebKit selection from being sent after a reload.

Links are rendered with HTML disabled. Use `<C-]>` or click a local file link to follow it, then `<C-^>` to switch between the current and previous file. `http`, `https`, and `mailto` links open externally only when clicked or followed from the cursor. Arbitrary WebKit file navigation is rejected. Markdown images are limited to safe URL schemes by markdown-it's renderer policy.

Markdown images are resolved relative to the opened Markdown file and displayed when the local image file exists. Image bytes are passed to the viewer directly, so the WebKit page does not need broader filesystem access. Remote images are replaced with a local placeholder and never fetched.

## Development

```sh
swift test
```

The tests cover prompt formatting and `/btw`, source-range clamping, pane ordering/target validation, pane ID zero, CLI parsing, JSON decoding, in-place watcher events, and atomic replacement saves. They never call the real WezTerm CLI or send a prompt.

## License

QuickMarkview is released under the MIT License. See `LICENSE`. Third-party notices and licenses are listed in `THIRD_PARTY_NOTICES.md`.
