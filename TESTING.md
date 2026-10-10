# TESTING.md

A running log of how changes to this repo were tested. One section per review, newest first.

## PR #67 and #68: Windows path handling in half-clone

PR: [ykdojo/claude-code-tips#67](https://github.com/ykdojo/claude-code-tips/pull/67) by Atticus-42, a follow-up to #64. Two changes: `convert_path_to_dirname` and `get_project_from_conv_file` learn Windows-style paths, and `test-half-clone.sh` gets the same UUID fallback chain as the main script so it can run on Git Bash. [#68](https://github.com/ykdojo/claude-code-tips/pull/68) is the review branch for it, and adds one fix of its own for a bug the review surfaced: escaping the project path in the history.jsonl entry (details below).

Verified on a real Windows runner in GitHub Actions ([run](https://github.com/delfinadap/claude-code-tips/actions/runs/32866554507), workflow on this branch) and on macOS locally:

- The conversion is correct both ways. `C:\Users\yurizen` and `C:/Users/yurizen` both map to `C--Users-yurizen`, the reverse mapping restores `C:\Users\yurizen`, and POSIX paths behave exactly as before.
- The bug is real and silent. The unpatched script, given a Windows-style project path, exits 0 but writes the clone into a mangled stray directory (`-C:...`) that Claude Code never reads. The patched script writes it next to the source conversation where it belongs.
- The test suite now runs on Git Bash. The unpatched suite dies immediately with `uuidgen: command not found`. The patched one passes 19/19 there, and still 19/19 on macOS, so no regression.
- One finding, fixed here in #68. The history.jsonl entry embedded the Windows path with raw backslashes (`"project":"C:\Users\..."`), which is not valid JSON. The escaping gap is pre-existing, but Windows paths only reach that code with #67. Impact was contained. Claude Code's shipped bundle parses each history line in its own try/catch and skips lines it cannot read, so only the clone's own history entry was lost, and that parsing lives in the cross-platform JS, no Windows environment needed to confirm it. #68 escapes the path the same way the display text already is, and CI now asserts the entry parses as JSON and the path round-trips exactly.
- Known ambiguity, shared with Claude Code's own convention. Hyphens in folder names reverse to separators, so `C:\Users\my-project` comes back as `C:\Users\my\project`.

Verdict: correct, minimal, safe to merge, with the history escaping fixed in #68 on top.

## PR #64: openssl UUID fallback for Windows/Git Bash

PR: [ykdojo/claude-code-tips#64](https://github.com/ykdojo/claude-code-tips/pull/64) by Atticus-42. One commit, one file (`scripts/half-clone-conversation.sh`, +8/-1).

The claim: the script's three ways of generating UUIDs all rely on tools Git Bash on Windows doesn't have, so half-clone fails there with "No UUID generation method available". Git Bash does ship `openssl`, so the PR adds it as a fallback.

Verified on a real Windows runner in GitHub Actions, whose default bash is Git Bash ([run](https://github.com/delfinadap/claude-code-tips/actions/runs/32756286008), workflow on the `test/pr64-windows-gitbash` branch):

- The claim holds. The three tools are missing, the unpatched script fails with exactly that error, the patched one writes a working clone.
- The clone is correct on Windows and macOS. Valid UUIDs, message links intact, no duplicates in a 10,000-UUID bulk run, no hidden Windows line-ending characters.
- Safe. Cryptographically strong randomness, no user input in the new commands, no new dependencies. Other platforms still use their original methods, so the new code only runs where it used to fail.

Verdict: correct, minimal, safe to merge.
