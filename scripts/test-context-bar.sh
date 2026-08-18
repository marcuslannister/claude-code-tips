#!/usr/bin/env bash
#
# test-context-bar.sh - Test suite for context-bar.sh
#
# Feeds mock status line payloads and scratch git repos to the script and
# checks what it renders.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTEXT_BAR_SCRIPT="${SCRIPT_DIR}/context-bar.sh"

# Test directory (isolated from real repos and Claude data)
TEST_DIR=$(mktemp -d)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# log_test names the case; the assertions below are what gets counted
log_test() { echo -e "${YELLOW}[TEST]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((++TESTS_RUN)) || true; ((++TESTS_PASSED)) || true; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((++TESTS_RUN)) || true; ((++TESTS_FAILED)) || true; }

cleanup_test_env() {
    rm -rf "$TEST_DIR"
}

# --- helpers ----------------------------------------------------------------

strip_ansi() { sed $'s/\033\[[0-9;]*m//g'; }

# Build a status line payload
# Args: cwd, [context window], [transcript path], [extra JSON fields], [model]
make_payload() {
    local cwd="$1"
    local window="${2:-200000}"
    local transcript="${3:-}"
    local extra="${4:-}"
    local model="${5:-Opus 5}"
    printf '{"model":{"display_name":"%s"},"cwd":"%s","context_window":{"context_window_size":%s},"transcript_path":"%s"%s}' \
        "$model" "$cwd" "$window" "$transcript" "$extra"
}

# Run the script and return its whole output. Never pipe into `head` here: the
# early close raises SIGPIPE while the script is still writing the second line,
# and `set -o pipefail` turns that into a failed test run.
render_all() {
    echo "$1" | bash "${2:-$CONTEXT_BAR_SCRIPT}"
}

# Render the first line with colors stripped
render() {
    local out
    out=$(render_all "$1" "${2:-$CONTEXT_BAR_SCRIPT}")
    printf '%s' "${out%%$'\n'*}" | strip_ansi
}

# Render the second line (the last user message) with colors stripped
render_message() {
    local out
    out=$(render_all "$1" "${2:-$CONTEXT_BAR_SCRIPT}")
    printf '%s' "${out#*$'\n'}" | strip_ansi
}

# Render the first line with the color escapes intact
render_raw() {
    local out
    out=$(render_all "$1" "${2:-$CONTEXT_BAR_SCRIPT}")
    printf '%s' "${out%%$'\n'*}"
}

# Copy the script with a specific COLOR theme, so color assertions do not
# depend on whichever theme the script currently ships with
themed_script() {
    local theme="$1"
    local out="${TEST_DIR}/context-bar-${theme}.sh"
    sed "s/^COLOR=\".*\"/COLOR=\"${theme}\"/" "$CONTEXT_BAR_SCRIPT" > "$out"
    printf '%s' "$out"
}

# Create a git repo with one committed file and a .gitignore
create_repo() {
    local path="$1"
    mkdir -p "$path"
    git init -q -b main "$path"
    git -C "$path" config user.email test@example.com
    git -C "$path" config user.name "Test"
    printf 'a\nb\nc\n' > "${path}/tracked.txt"
    printf 'ignored/\n' > "${path}/.gitignore"
    git -C "$path" add -A
    git -C "$path" commit -qm "init"
}

# Create a transcript with a usage entry and a user message
# Args: file, context tokens, user message
create_transcript() {
    local file="$1" tokens="$2" message="$3"
    {
        printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$message"
        printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' "$tokens"
    } > "$file"
}

assert_contains() {
    local haystack="$1" needle="$2" description="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        log_pass "$description"
    else
        log_fail "$description"
        echo "       expected to contain: $needle"
        echo "       got:                 $haystack"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" description="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        log_pass "$description"
    else
        log_fail "$description"
        echo "       expected to omit: $needle"
        echo "       got:              $haystack"
    fi
}

# --- git segment ------------------------------------------------------------

test_clean_repo_has_no_counts() {
    log_test "A clean repo shows the branch with no counts"
    local repo="${TEST_DIR}/clean"
    create_repo "$repo"
    local out
    out=$(render "$(make_payload "$repo")")
    assert_contains "$out" "🌿 main " "Branch renders on its own"
    assert_not_contains "$out" "main(" "Clean repo renders no (…) suffix"
}

test_untracked_only_is_visible() {
    log_test "Untracked files alone still mark the tree as dirty"
    local repo="${TEST_DIR}/untracked"
    create_repo "$repo"
    touch "${repo}/new1.txt" "${repo}/new2.txt"
    local out
    out=$(render "$(make_payload "$repo")")
    assert_contains "$out" "main(?2)" "Untracked-only work shows ?2"
}

test_edits_and_untracked() {
    log_test "Line changes and untracked files render together"
    local repo="${TEST_DIR}/mixed"
    create_repo "$repo"
    printf 'a\nb\nc\nd\n' > "${repo}/tracked.txt"
    touch "${repo}/new1.txt"
    local out
    out=$(render "$(make_payload "$repo")")
    assert_contains "$out" "main(+1,-0,?1)" "Both counts appear in one group"
}

test_edits_only() {
    log_test "Line changes alone render without a ? count"
    local repo="${TEST_DIR}/edits"
    create_repo "$repo"
    printf 'a\nb\n' > "${repo}/tracked.txt"
    local out
    out=$(render "$(make_payload "$repo")")
    assert_contains "$out" "main(+0,-1)" "Edits render as +0,-1"
    assert_not_contains "$out" "?" "No ? count when nothing is untracked"
}

test_ignored_files_not_counted() {
    log_test "Ignored files are not counted as untracked"
    local repo="${TEST_DIR}/ignored"
    create_repo "$repo"
    mkdir -p "${repo}/ignored"
    touch "${repo}/ignored/a" "${repo}/ignored/b"
    local out
    out=$(render "$(make_payload "$repo")")
    assert_not_contains "$out" "?" "Ignored paths stay out of the count"
}

test_non_git_dir_omits_branch() {
    log_test "A directory outside git omits the branch segment"
    local plain="${TEST_DIR}/plain"
    mkdir -p "$plain"
    local out
    out=$(render "$(make_payload "$plain")")
    assert_not_contains "$out" "🌿" "No branch segment without a repo"
}

# --- model and thinking -----------------------------------------------------

test_model_context_suffix_stripped() {
    log_test "The (1M context) suffix is stripped from the model name"
    local out
    out=$(render "$(make_payload "${TEST_DIR}" 1000000 "" "" "Opus 5 (1M context)")")
    assert_contains "$out" "🤖 Opus 5 " "Model renders without the suffix"
    assert_not_contains "$out" "1M context" "Suffix is gone"
}

test_thinking_from_effort_level() {
    log_test "Thinking effort comes from .effort.level"
    local out
    out=$(render "$(make_payload "${TEST_DIR}" 200000 "" ',"effort":{"level":"medium"}')")
    assert_contains "$out" "🧠 medium" "Effort level renders"
}

test_thinking_off_when_disabled() {
    log_test "Thinking shows off when .thinking.enabled is false"
    local out
    out=$(render "$(make_payload "${TEST_DIR}" 200000 "" ',"thinking":{"enabled":false}')")
    assert_contains "$out" "🧠 off" "Disabled thinking renders as off"
}

test_thinking_omitted_when_unknown() {
    log_test "The thinking segment is omitted when the payload says nothing"
    local out
    out=$(render "$(make_payload "${TEST_DIR}")")
    assert_not_contains "$out" "🧠" "No thinking segment without data"
}

# --- context ----------------------------------------------------------------

test_context_from_transcript() {
    log_test "Context usage is read from the transcript"
    local transcript="${TEST_DIR}/usage.jsonl"
    create_transcript "$transcript" 50000 "hello"
    local out
    out=$(render "$(make_payload "${TEST_DIR}" 200000 "$transcript")")
    assert_contains "$out" "50k/200k (25%)" "Usage and percent match the transcript"
}

test_baseline_without_transcript() {
    log_test "Without a transcript the bar shows the ~20k baseline"
    local out
    out=$(render "$(make_payload "${TEST_DIR}")")
    assert_contains "$out" "20k/200k (~10%)" "Baseline estimate is marked with ~"
}

test_million_window_formatting() {
    log_test "A 1M context window is formatted with one decimal"
    local transcript="${TEST_DIR}/usage-1m.jsonl"
    create_transcript "$transcript" 250000 "hello"
    local out
    out=$(render "$(make_payload "${TEST_DIR}" 1000000 "$transcript")")
    assert_contains "$out" "250k/1.0M (25%)" "Tokens render as 250k/1.0M"
}

test_bar_fill_tracks_usage() {
    log_test "The bar fills in proportion to usage"
    local transcript="${TEST_DIR}/usage-half.jsonl"
    create_transcript "$transcript" 100000 "hello"
    local out filled
    out=$(render "$(make_payload "${TEST_DIR}" 200000 "$transcript")")
    # grep -o counts characters; `tr -cd` would count UTF-8 bytes instead
    filled=$(printf '%s' "$out" | grep -o '█' | wc -l | tr -d ' ')
    if [[ "$filled" -eq 8 ]]; then
        log_pass "50% usage fills 8 of 16 segments"
    else
        log_fail "50% usage fills 8 of 16 segments (got $filled)"
    fi
}

test_bar_threshold_colors() {
    log_test "The modus bar changes color at 60% and 85%"
    local script transcript out
    script=$(themed_script "modus")

    create_transcript "${TEST_DIR}/pct-40.jsonl" 80000 "hello"
    out=$(render_raw "$(make_payload "${TEST_DIR}" 200000 "${TEST_DIR}/pct-40.jsonl")" "$script")
    assert_contains "$out" '38;2;137;64;0m█' "Below 60% fills with orange"

    create_transcript "${TEST_DIR}/pct-70.jsonl" 140000 "hello"
    out=$(render_raw "$(make_payload "${TEST_DIR}" 200000 "${TEST_DIR}/pct-70.jsonl")" "$script")
    assert_contains "$out" '38;2;151;37;0m█' "Past 60% fills with red-warmer"

    create_transcript "${TEST_DIR}/pct-90.jsonl" 180000 "hello"
    out=$(render_raw "$(make_payload "${TEST_DIR}" 200000 "${TEST_DIR}/pct-90.jsonl")" "$script")
    assert_contains "$out" '38;2;208;0;0m█' "Past 85% fills with red-intense"
}

test_other_themes_have_one_bar_color() {
    log_test "Themes without thresholds keep a single bar color"
    local script transcript out
    script=$(themed_script "blue")
    create_transcript "${TEST_DIR}/pct-90-blue.jsonl" 180000 "hello"
    out=$(render_raw "$(make_payload "${TEST_DIR}" 200000 "${TEST_DIR}/pct-90-blue.jsonl")" "$script")
    assert_contains "$out" '38;5;74m█' "The blue theme fills with its accent at 90%"
}

# --- second line ------------------------------------------------------------

test_last_message_line() {
    log_test "The second line shows the last user message"
    local transcript="${TEST_DIR}/message.jsonl"
    create_transcript "$transcript" 1000 "what does this script do"
    local out
    out=$(render_message "$(make_payload "${TEST_DIR}" 200000 "$transcript")")
    assert_contains "$out" "💬 what does this script do" "Message renders after the icon"
}

test_interrupted_message_skipped() {
    log_test "Interrupted messages are skipped in favor of a real one"
    local transcript="${TEST_DIR}/interrupted.jsonl"
    {
        printf '{"type":"user","message":{"role":"user","content":"the real message"}}\n'
        printf '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":1000}}}\n'
        printf '{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"}}\n'
    } > "$transcript"
    local out
    out=$(render_message "$(make_payload "${TEST_DIR}" 200000 "$transcript")")
    assert_contains "$out" "the real message" "Falls back to the last useful message"
}

test_long_message_truncated() {
    log_test "A long message is truncated to the width of the first line"
    local transcript="${TEST_DIR}/long.jsonl"
    local long_message
    long_message=$(printf 'x%.0s' $(seq 1 400))
    create_transcript "$transcript" 1000 "$long_message"
    local first second
    first=$(render "$(make_payload "${TEST_DIR}" 200000 "$transcript")")
    second=$(render_message "$(make_payload "${TEST_DIR}" 200000 "$transcript")")
    if [[ "$second" == *"..." && ${#second} -le $((${#first} + 8)) ]]; then
        log_pass "Long message is cut to roughly the first line width"
    else
        log_fail "Long message is cut to roughly the first line width"
        echo "       first line:  ${#first} chars"
        echo "       second line: ${#second} chars"
    fi
}

# --- layout -----------------------------------------------------------------

test_segment_icons_present() {
    log_test "Every segment carries its icon"
    local repo="${TEST_DIR}/icons"
    create_repo "$repo"
    local out
    out=$(render "$(make_payload "$repo" 200000 "" ',"effort":{"level":"high"}')")
    assert_contains "$out" "🤖" "Model icon"
    assert_contains "$out" "🧠" "Thinking icon"
    assert_contains "$out" "📁" "Path icon"
    assert_contains "$out" "🌿" "Branch icon"
    assert_contains "$out" "🧭" "Context icon"
}

# --- main -------------------------------------------------------------------

main() {
    echo "Context Bar Tests"
    echo "================================"
    echo ""

    if [ ! -f "$CONTEXT_BAR_SCRIPT" ]; then
        echo "Error: context-bar.sh not found at $CONTEXT_BAR_SCRIPT"
        exit 1
    fi

    if ! command -v jq > /dev/null 2>&1; then
        echo "Error: jq is required to run these tests"
        exit 1
    fi

    trap cleanup_test_env EXIT

    test_clean_repo_has_no_counts
    test_untracked_only_is_visible
    test_edits_and_untracked
    test_edits_only
    test_ignored_files_not_counted
    test_non_git_dir_omits_branch
    test_model_context_suffix_stripped
    test_thinking_from_effort_level
    test_thinking_off_when_disabled
    test_thinking_omitted_when_unknown
    test_context_from_transcript
    test_baseline_without_transcript
    test_million_window_formatting
    test_bar_fill_tracks_usage
    test_bar_threshold_colors
    test_other_themes_have_one_bar_color
    test_last_message_line
    test_interrupted_message_skipped
    test_long_message_truncated
    test_segment_icons_present

    echo ""
    echo "================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "${RED}$TESTS_FAILED tests failed${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
    fi
}

main "$@"
