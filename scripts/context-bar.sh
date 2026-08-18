#!/bin/bash

# Color theme: gray, orange, blue, teal, green, lavender, rose, gold, slate, cyan,
# modus (light background, 24-bit color - see the modus block below)
COLOR="modus"

# Segment icons - swap these for text labels (e.g. E_MODEL="Model:") if your
# terminal font renders emoji poorly
E_MODEL="🤖"
E_THINKING="💭"
E_PATH="📁"
E_BRANCH="🌿"
E_CONTEXT="🪟"

# Color codes
# Defaults are 256-color and assume a dark terminal background. A theme may
# override any of them; anything left unset falls back to the accent color.
C_RESET='\033[0m'
C_VALUE='\033[38;5;245m'   # gray for values and separators
C_BAR_EMPTY='\033[38;5;238m'
C_ADDED='\033[38;5;71m'     # green for added lines
C_DELETED='\033[38;5;173m'  # orange for deleted lines
C_UNTRACKED='\033[38;5;179m' # gold for the untracked file count
C_SEP=""      # separators between segments
C_BRANCH=""   # git branch segment
C_BAR_FILL="" # filled part of the context bar
C_BAR_WARN="" # bar fill past BAR_WARN_PCT (empty = no threshold colors)
C_BAR_ERR=""  # bar fill past BAR_ERR_PCT
BAR_WARN_PCT=60
BAR_ERR_PCT=85

case "$COLOR" in
    orange)   C_ACCENT='\033[38;5;173m' ;;
    blue)     C_ACCENT='\033[38;5;74m' ;;
    teal)     C_ACCENT='\033[38;5;66m' ;;
    green)    C_ACCENT='\033[38;5;71m' ;;
    lavender) C_ACCENT='\033[38;5;139m' ;;
    rose)     C_ACCENT='\033[38;5;132m' ;;
    gold)     C_ACCENT='\033[38;5;136m' ;;
    slate)    C_ACCENT='\033[38;5;60m' ;;
    cyan)     C_ACCENT='\033[38;5;37m' ;;
    modus)
        # modus-operandi-tinted (Emacs), for a light terminal on bg-main #fbf7f0.
        # Each slot maps to one of the theme's semantic colors:
        #   labels     keyword          blue              #0031a9
        #   values     fg-dim                             #595959
        #   separator  border                             #9f9690
        #   branch     name             magenta           #721045
        #   added      fg-added-intense                   #006700
        #   deleted    fg-removed-intense                 #aa2222
        #   untracked  fg-changed                         #553d00
        #   bar fill   accent-3/red-warmer/red-intense  orange/red by usage
        #   bar track  fg-dim                             #595959
        C_ACCENT='\033[38;2;0;49;169m'
        C_VALUE='\033[38;2;89;89;89m'
        C_SEP='\033[38;2;159;150;144m'
        C_BRANCH='\033[38;2;114;16;69m'
        C_ADDED='\033[38;2;0;103;0m'
        C_DELETED='\033[38;2;170;34;34m'
        C_UNTRACKED='\033[38;2;85;61;0m'
        C_BAR_FILL='\033[38;2;137;64;0m'
        C_BAR_WARN='\033[38;2;151;37;0m'
        C_BAR_ERR='\033[38;2;208;0;0m'
        C_BAR_EMPTY='\033[38;2;89;89;89m'
        ;;
    *)        C_ACCENT="$C_VALUE" ;;  # gray: all same color
esac

# Unset slots follow the accent color, keeping the simpler themes single-accent
C_SEP="${C_SEP:-$C_VALUE}"
C_BRANCH="${C_BRANCH:-$C_ACCENT}"
C_BAR_FILL="${C_BAR_FILL:-$C_ACCENT}"

input=$(cat)

# Extract model, thinking effort, and cwd
# Drop the "(1M context)" suffix - the context bar already shows the window size
model=$(echo "$input" | jq -r '(.model.display_name // .model.id // "?") | sub(" *\\(1M context\\)$"; "")')
cwd=$(echo "$input" | jq -r '.cwd // empty')
dir=$(basename "$cwd" 2>/dev/null || echo "?")

# Thinking effort: .effort.level (low/medium/high) is only present on models
# that support it - fall back to on/off from .thinking.enabled
effort=$(echo "$input" | jq -r '.effort.level // empty')
if [[ -z "$effort" ]]; then
    # Note: `// empty` would swallow `false` here, so test for null explicitly
    thinking_enabled=$(echo "$input" | jq -r 'if .thinking.enabled == null then empty else (.thinking.enabled | tostring) end')
    case "$thinking_enabled" in
        true)  effort="on" ;;
        false) effort="off" ;;
    esac
fi

# Get git branch, uncommitted line changes (+added,-deleted), and untracked count
branch=""
diff_stat=""
diff_plain=""
if [[ -n "$cwd" && -d "$cwd" ]]; then
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
    if [[ -n "$branch" ]]; then
        # Sum line changes across tracked files (binary files count as 0)
        counts=$(git -C "$cwd" --no-optional-locks diff --numstat HEAD 2>/dev/null |
            awk '{ added += $1; deleted += $2 } END { print added + 0, deleted + 0 }')
        added=$(echo "$counts" | cut -d' ' -f1)
        deleted=$(echo "$counts" | cut -d' ' -f2)

        # `git diff` never reports untracked paths, so count them separately -
        # otherwise a tree whose only work is new files looks clean
        untracked=$(git -C "$cwd" --no-optional-locks ls-files --others --exclude-standard 2>/dev/null |
            wc -l | tr -d ' ')

        parts=""
        parts_plain=""
        if [[ "${added:-0}" -gt 0 || "${deleted:-0}" -gt 0 ]]; then
            parts="${C_ADDED}+${added}${C_SEP},${C_DELETED}-${deleted}"
            parts_plain="+${added},-${deleted}"
        fi
        if [[ "${untracked:-0}" -gt 0 ]]; then
            [[ -n "$parts" ]] && { parts+="${C_SEP},"; parts_plain+=","; }
            parts+="${C_UNTRACKED}?${untracked}"
            parts_plain+="?${untracked}"
        fi
        if [[ -n "$parts" ]]; then
            diff_stat="${C_SEP}(${parts}${C_SEP})"
            diff_plain="(${parts_plain})"
        fi
    fi
fi

# Get transcript path for context calculation and last message feature
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

# Format a token count as 0 / 50k / 1.0M (same rounding as ccstatusline)
format_tokens() {
    local n=$1
    if [[ $n -ge 999950 ]]; then
        awk -v n="$n" 'BEGIN { printf "%.1fM", n / 1000000 }'
    elif [[ $n -ge 1000 ]]; then
        awk -v n="$n" 'BEGIN { printf "%.0fk", n / 1000 }'
    else
        printf '%d' "$n"
    fi
}

# Draw a bar of BAR_WIDTH segments for a percentage
BAR_WIDTH=16
build_bar() {
    local pct=$1 filled i bar="" fill="$C_BAR_FILL"
    [[ -n "$C_BAR_WARN" && $pct -ge $BAR_WARN_PCT ]] && fill="$C_BAR_WARN"
    [[ -n "$C_BAR_ERR" && $pct -ge $BAR_ERR_PCT ]] && fill="$C_BAR_ERR"
    filled=$(((pct * BAR_WIDTH + 50) / 100))
    for ((i=0; i<BAR_WIDTH; i++)); do
        if [[ $i -lt $filled ]]; then
            bar+="${fill}█"
        else
            bar+="${C_BAR_EMPTY}░"
        fi
    done
    printf '%s' "$bar"
}

# Get context window size from JSON (accurate), but calculate tokens from transcript
# (more accurate than total_input_tokens which excludes system prompt/tools/memory)
# See: github.com/anthropics/claude-code/issues/13652
max_context=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
max_display=$(format_tokens "$max_context")

# Calculate context bar from transcript
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    context_length=$(jq -s '
        map(select(.message.usage and .isSidechain != true and .isApiErrorMessage != true)) |
        last |
        if . then
            (.message.usage.input_tokens // 0) +
            (.message.usage.cache_read_input_tokens // 0) +
            (.message.usage.cache_creation_input_tokens // 0)
        else 0 end
    ' < "$transcript_path")

    # 20k baseline: includes system prompt (~3k), tools (~15k), memory (~300),
    # plus ~2k for git status, env block, XML framing, and other dynamic context
    baseline=20000

    if [[ "$context_length" -gt 0 ]]; then
        used=$context_length
        pct_prefix=""
    else
        # At conversation start, ~20k baseline is already loaded
        used=$baseline
        pct_prefix="~"
    fi
else
    # Transcript not available yet - show baseline estimate
    used=20000
    pct_prefix="~"
fi

pct=$(((used * 200 + max_context) / (2 * max_context)))  # round to nearest percent
[[ $pct -gt 100 ]] && pct=100
used_display=$(format_tokens "$used")
ctx="${C_SEP}[$(build_bar "$pct")${C_SEP}]${C_VALUE} ${used_display}/${max_display} (${pct_prefix}${pct}%)"
ctx_plain="[$(printf '%*s' "$BAR_WIDTH" '' | tr ' ' 'x')] ${used_display}/${max_display} (${pct_prefix}${pct}%)"

# Build output: model | thinking | path | branch(+added,-deleted) | context
sep="${C_SEP} | "
output="${E_MODEL}${C_VALUE} ${model}"
[[ -n "$effort" ]] && output+="${sep}${E_THINKING}${C_VALUE} ${effort}"
[[ -n "$dir" ]] && output+="${sep}${E_PATH}${C_VALUE} ${dir}"
[[ -n "$branch" ]] && output+="${sep}${E_BRANCH}${C_BRANCH} ${branch}${diff_stat}"
output+="${sep}${E_CONTEXT}${C_VALUE} ${ctx}${C_RESET}"

printf '%b\n' "$output"

# Get user's last message (text only, not tool results, skip unhelpful messages)
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    # Calculate visible length (without ANSI codes) - bar chars + content.
    # Emoji count as one character here but take two terminal columns, so add
    # one column per icon shown.
    wide=2  # model and context icons are always shown
    plain_output="${E_MODEL} ${model}"
    [[ -n "$effort" ]] && { plain_output+=" | ${E_THINKING} ${effort}"; wide=$((wide + 1)); }
    [[ -n "$dir" ]] && { plain_output+=" | ${E_PATH} ${dir}"; wide=$((wide + 1)); }
    [[ -n "$branch" ]] && { plain_output+=" | ${E_BRANCH} ${branch}${diff_plain}"; wide=$((wide + 1)); }
    plain_output+=" | ${E_CONTEXT} ${ctx_plain}"
    max_len=$((${#plain_output} + wide))
    last_user_msg=$(jq -rs '
        # Messages to skip (not useful as context)
        def is_unhelpful:
            startswith("[Request interrupted") or
            startswith("[Request cancelled") or
            . == "";

        [.[] | select(.type == "user") |
         select(.message.content | type == "string" or
                (type == "array" and any(.[]; .type == "text")))] |
        reverse |
        map(.message.content |
            if type == "string" then .
            else [.[] | select(.type == "text") | .text] | join(" ") end |
            gsub("\n"; " ") | gsub("  +"; " ")) |
        map(select(is_unhelpful | not)) |
        first // ""
    ' < "$transcript_path" 2>/dev/null)

    if [[ -n "$last_user_msg" ]]; then
        if [[ ${#last_user_msg} -gt $max_len ]]; then
            echo "💬 ${last_user_msg:0:$((max_len - 3))}..."
        else
            echo "💬 ${last_user_msg}"
        fi
    fi
fi
