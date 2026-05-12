# gh-heatmap: GitHub 7-day activity heatmap for zsh prompt
#
# Configuration (set in ~/.zshrc before plugins line):
#   GH_HEATMAP_USERNAME   GitHub username (default: GITHUB_USERNAME or git config github.user)
#   GH_HEATMAP_TOKEN      GitHub PAT with read:user scope — enables GraphQL (full contribution data)
#                         Falls back to public REST events API if unset/expired
#   GH_HEATMAP_CACHE_TTL  Cache lifetime in seconds (default: 300)
#   GH_HEATMAP_CACHE_DIR  Cache directory (default: ~/.cache/gh-heatmap)
#
# Powerlevel10k integration (recommended):
#   Add 'gh_heatmap' to POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS in ~/.p10k.zsh
#
# Other themes / manual RPROMPT:
#   RPROMPT='$(gh_heatmap_segment) '$RPROMPT

# ── defaults ─────────────────────────────────────────────────────────────────
: ${GH_HEATMAP_CACHE_TTL:=300}
: ${GH_HEATMAP_CACHE_DIR:=${XDG_CACHE_HOME:-$HOME/.cache}/gh-heatmap}

_gh_heatmap_username() {
    local u="${GH_HEATMAP_USERNAME:-${GITHUB_USERNAME:-}}"
    [[ -z "$u" ]] && u="$(git config --global github.user 2>/dev/null)"
    printf '%s' "$u"
}

# ── cache paths ──────────────────────────────────────────────────────────────
_gh_heatmap_base() {
    local u; u="$(_gh_heatmap_username)"
    [[ -z "$u" ]] && return 1
    printf '%s/%s' "$GH_HEATMAP_CACHE_DIR" "$u"
}

# ── staleness check ──────────────────────────────────────────────────────────
_gh_heatmap_is_stale() {
    local base ts
    base="$(_gh_heatmap_base)" || return 0   # no username → always stale
    ts="${base}.ts"
    [[ ! -f "$ts" ]] && return 0
    (( $(date +%s) - $(< "$ts") >= GH_HEATMAP_CACHE_TTL ))
}

# ── fetch + render (runs in background) ──────────────────────────────────────
_gh_heatmap_refresh() {
    local user base tmp token
    user="$(_gh_heatmap_username)"
    [[ -z "$user" ]] && return 1
    base="${GH_HEATMAP_CACHE_DIR}/${user}"
    tmp="${base}.tmp"
    token="${GH_HEATMAP_TOKEN:-${GITHUB_TOKEN:-}}"
    mkdir -p "$GH_HEATMAP_CACHE_DIR"

    local ok=0

    if [[ -n "$token" ]]; then
        # GraphQL: full contribution calendar (private + public)
        local query
        query='{"query":"{user(login:\"'"$user"'\"){contributionsCollection{contributionCalendar{weeks{contributionDays{date contributionCount}}}}}}"}'
        command curl -sf \
            -H "Authorization: bearer ${token}" \
            -H "Content-Type: application/json" \
            --max-time 10 \
            -d "$query" \
            "https://api.github.com/graphql" \
            -o "${tmp}.graphql" 2>/dev/null && \
        # Validate response has expected structure
        python3 -c "
import json, sys
d = json.load(open('${tmp}.graphql'))
_ = d['data']['user']['contributionsCollection']
" 2>/dev/null && \
        mv "${tmp}.graphql" "${base}.graphql" && ok=1
    fi

    if (( ! ok )); then
        # REST fallback: public events only
        command curl -sf \
            ${token:+-H "Authorization: token ${token}"} \
            -H "Accept: application/vnd.github.v3+json" \
            --max-time 10 \
            "https://api.github.com/users/${user}/events?per_page=100" \
            -o "${tmp}.rest" 2>/dev/null && \
        python3 -c "import json; json.load(open('${tmp}.rest'))" 2>/dev/null && \
        mv "${tmp}.rest" "${base}.rest" && ok=1
    fi

    (( ok )) || return 1

    # Render to cached string
    _gh_heatmap_render_to_file "$base"
    date +%s > "${base}.ts"
}

# ── render: compute colored blocks, write to .rendered ───────────────────────
_gh_heatmap_render_to_file() {
    local base="$1"
    local counts

    if [[ -f "${base}.graphql" ]]; then
        counts=$(python3 - "${base}.graphql" 2>/dev/null <<'PY'
import json, sys
from datetime import date, timedelta
today = date.today()
dates = [(today - timedelta(days=i)).strftime('%Y-%m-%d') for i in range(6, -1, -1)]
try:
    data = json.load(open(sys.argv[1]))
    days = {}
    for week in data['data']['user']['contributionsCollection']['contributionCalendar']['weeks']:
        for d in week['contributionDays']:
            days[d['date']] = d['contributionCount']
    print(' '.join(str(days.get(d, 0)) for d in dates))
except Exception as e:
    print('0 0 0 0 0 0 0')
PY
)
    elif [[ -f "${base}.rest" ]]; then
        counts=$(python3 - "${base}.rest" 2>/dev/null <<'PY'
import json, sys
from datetime import date, timedelta
today = date.today()
dates = [(today - timedelta(days=i)).strftime('%Y-%m-%d') for i in range(6, -1, -1)]
day_counts = {d: 0 for d in dates}
try:
    for ev in json.load(open(sys.argv[1])):
        dt = ev.get('created_at', '')[:10]
        if dt in day_counts:
            day_counts[dt] += 1
    print(' '.join(str(day_counts[d]) for d in dates))
except:
    print('0 0 0 0 0 0 0')
PY
)
    else
        return 1
    fi

    [[ -z "$counts" ]] && return 1

    # Color levels: 0=dark-gray  1-2=dark-green  3-5=mid-green  6-10=green  11+=bright-green
    local seg="" c
    for c in ${(s: :)counts}; do
        if   (( c == 0 ));  then seg+="%F{238}■%f"
        elif (( c <= 2 ));  then seg+="%F{22}■%f"
        elif (( c <= 5 ));  then seg+="%F{28}■%f"
        elif (( c <= 10 )); then seg+="%F{34}■%f"
        else                     seg+="%F{46}■%f"
        fi
    done

    printf '%s' "${seg}" > "${base}.rendered"
}

# ── in-memory cache for current prompt ───────────────────────────────────────
_GH_HEATMAP_SEGMENT=""

_gh_heatmap_load_rendered() {
    local base
    base="$(_gh_heatmap_base)" || return
    local f="${base}.rendered"
    [[ -f "$f" ]] && _GH_HEATMAP_SEGMENT="$(< "$f")" || _GH_HEATMAP_SEGMENT=""
}

# ── precmd hook ───────────────────────────────────────────────────────────────
_gh_heatmap_precmd() {
    if git rev-parse --git-dir &>/dev/null 2>&1; then
        if _gh_heatmap_is_stale; then
            # Fetch + render in background; result available next prompt
            ( _gh_heatmap_refresh ) &!
        fi
        _gh_heatmap_load_rendered
    else
        _GH_HEATMAP_SEGMENT=""
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _gh_heatmap_precmd

# ── public API ────────────────────────────────────────────────────────────────

# For non-P10k themes: add $(gh_heatmap_segment) to your RPROMPT
gh_heatmap_segment() {
    printf '%s' "$_GH_HEATMAP_SEGMENT"
}

# Force a fresh fetch (useful after a burst of commits)
gh_heatmap_refresh() {
    local base
    base="$(_gh_heatmap_base)" || { echo "gh-heatmap: no username configured" >&2; return 1; }
    rm -f "${base}.ts"
    _gh_heatmap_refresh && _gh_heatmap_load_rendered && \
        echo "gh-heatmap: refreshed" || echo "gh-heatmap: fetch failed" >&2
}

# ── Powerlevel10k segment ─────────────────────────────────────────────────────
# Reads from the in-memory variable set by precmd — no I/O in prompt path.
function prompt_gh_heatmap() {
    [[ -z "$_GH_HEATMAP_SEGMENT" ]] && return
    p10k segment -t "$_GH_HEATMAP_SEGMENT"
}

# Instant-prompt variant: same logic, safe to call before shell is fully init'd
function instant_prompt_gh_heatmap() {
    prompt_gh_heatmap
}
