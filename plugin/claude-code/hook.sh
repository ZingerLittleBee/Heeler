#!/bin/sh
# Heeler's Claude Code hook for tmux Panes (ADR 0044). The app keeps this one
# file in Heeler's own directory on the Host, apart from the Host Helper, and
# Heeler's hook entries run it for each event they name. Inside a tmux Pane it
# writes the Pane's `@heeler-status`, continuing its counts as
# plugin/test-vectors/tmux-heeler-status-v1.json says, and `@heeler-session`,
# through the tmux the app stored for the server named in `TMUX`. Outside a
# tmux Pane, for a Claude Code that does not lead the Pane's foreground, or
# without stored paths for that server, it does nothing. It never fails a hook.
#
# `hook.sh continue <value> <state> <app> [kind] [msg]` prints what a report
# makes of a value, which the shared vector checks.

LC_ALL=C
export LC_ALL

APP=claude-code
STATUS_OPTION=@heeler-status
SESSION_OPTION=@heeler-session
# The questions Claude Code has open in this Pane while it reads blocked: the
# asking process, then one entry per question, each its tool's fingerprint, or
# `u` for a prompt that named no tool.
ASK_OPTION=@heeler-ask
# Programs known to report done, so their idle ends no turn (the shared vector).
DONE_REPORTERS="claude-code codex pi omp grok-build"
# Characters, as the Pi extension keeps a message.
MESSAGE_LIMIT=512
SEP=$(printf '\037')

# Top-level members of a JSON object read from stdin: one line of
# `name<TAB>raw value` for each member named in `want`, raw values with their
# own line breaks as spaces. It stops at the member named `stop`, past which
# nothing is wanted. Anything it can't read ends the output there.
JSON_MEMBERS='
function blank(c) { return c == " " || c == "\t" || c == "\n" || c == "\r" }
function skip_blanks() { while (at <= n && blank(substr(text, at, 1))) at++ }
function skip_string(   c) {
  at++
  while (at <= n) {
    c = substr(text, at, 1)
    if (c == "\\") at += 2
    else if (c == "\"") { at++; return 1 }
    else at++
  }
  return 0
}
function skip_value(   c, depth) {
  c = substr(text, at, 1)
  if (c == "\"") return skip_string()
  if (c == "{" || c == "[") {
    depth = 0
    while (at <= n) {
      c = substr(text, at, 1)
      if (c == "\"") { if (!skip_string()) return 0; continue }
      if (c == "{" || c == "[") depth++
      else if (c == "}" || c == "]") { depth--; if (depth == 0) { at++; return 1 } }
      at++
    }
    return 0
  }
  while (at <= n) {
    c = substr(text, at, 1)
    if (c == "," || c == "}" || c == "]" || blank(c)) break
    at++
  }
  return 1
}
BEGIN { count = split(want, names, " "); for (k = 1; k <= count; k++) wanted[names[k]] = 1 }
{ text = NR == 1 ? $0 : text "\n" $0 }
END {
  n = length(text); at = 1
  skip_blanks()
  if (substr(text, at, 1) != "{") exit
  at++
  while (1) {
    skip_blanks()
    if (substr(text, at, 1) != "\"") exit
    start = at
    if (!skip_string()) exit
    key = substr(text, start + 1, at - start - 2)
    if (key == stop) exit
    skip_blanks()
    if (substr(text, at, 1) != ":") exit
    at++
    skip_blanks()
    start = at
    if (!skip_value()) exit
    if (key in wanted) {
      value = substr(text, start, at - start)
      gsub(/[\t\n\r]/, " ", value)
      print key "\t" value
    }
    skip_blanks()
    if (substr(text, at, 1) != ",") exit
    at++
  }
}'

# A JSON string's text from its literal, for the plain strings a path or a name
# is, or nothing for one this does not read.
json_text() {
  case $1 in
    \"*\") ;;
    *) return 1 ;;
  esac
  text=${1#\"}
  text=${text%\"}
  case $text in
    *\\u*) return 1 ;;
  esac
  printf '%s' "$text" | sed -e 's/\\"/"/g' -e 's/\\\//\//g' -e 's/\\\\/\\/g'
}

# OSC 7501's message from a JSON string literal: its first line, control
# characters as spaces, trimmed, at most MESSAGE_LIMIT characters, in base64.
# Nothing for an empty one.
JSON_MESSAGE='
function hex(c) { return index("0123456789abcdef", tolower(c)) - 1 }
function put(code) {
  if (code < 32 || code == 127 || (code >= 128 && code < 160)) code = 32
  if (code < 128) { out[++len] = code }
  else if (code < 2048) { out[++len] = 192 + int(code / 64); out[++len] = 128 + code % 64 }
  else if (code < 65536) {
    out[++len] = 224 + int(code / 4096); out[++len] = 128 + int(code / 64) % 64; out[++len] = 128 + code % 64
  } else {
    out[++len] = 240 + int(code / 262144); out[++len] = 128 + int(code / 4096) % 64
    out[++len] = 128 + int(code / 64) % 64; out[++len] = 128 + code % 64
  }
  chars++
}
{ for (k = 1; k <= NF; k++) bytes[++total] = $k }
END {
  if (total < 2 || bytes[1] != 34) exit
  len = 0; chars = 0; k = 2
  while (k < total && chars < limit) {
    b = bytes[k]
    if (b == 92) {
      e = bytes[k + 1]
      if (e == 110 || e == 114) break
      if (e == 117) {
        code = 0
        for (d = 2; d <= 5; d++) code = code * 16 + hex(sprintf("%c", bytes[k + d]))
        k += 6
        if (code >= 55296 && code < 56320 && bytes[k] == 92 && bytes[k + 1] == 117) {
          low = 0
          for (d = 2; d <= 5; d++) low = low * 16 + hex(sprintf("%c", bytes[k + d]))
          if (low >= 56320 && low < 57344) { code = 65536 + (code - 55296) * 1024 + (low - 56320); k += 6 }
        }
        put(code)
        continue
      }
      if (e == 116 || e == 98 || e == 102) put(32)
      else put(e)
      k += 2
      continue
    }
    if (b == 10 || b == 13) break
    if (b < 32 || b == 127) { put(32); k++; continue }
    out[++len] = b
    if (b < 128 || b >= 192) chars++
    k++
    while (k < total && bytes[k] >= 128 && bytes[k] < 192) { out[++len] = bytes[k]; k++ }
  }
  first = 1
  while (first <= len && (out[first] == 32 || out[first] == 9)) first++
  while (len >= first && (out[len] == 32 || out[len] == 9)) len--
  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  line = ""
  for (k = first; k <= len; k += 3) {
    a = out[k]; b1 = k + 1 <= len ? out[k + 1] : 0; c = k + 2 <= len ? out[k + 2] : 0
    word = a * 65536 + b1 * 256 + c
    line = line substr(alphabet, int(word / 262144) + 1, 1) substr(alphabet, int(word / 4096) % 64 + 1, 1)
    line = line (k + 1 <= len ? substr(alphabet, int(word / 64) % 64 + 1, 1) : "=")
    line = line (k + 2 <= len ? substr(alphabet, word % 64 + 1, 1) : "=")
  }
  if (line != "") print line
}'

status_message() {
  [ -n "$1" ] || return 0
  printf '%s' "$1" | od -An -v -tu1 | awk -v limit="$MESSAGE_LIMIT" "$JSON_MESSAGE"
}

# A whole number with no leading zeros, as `Number` reads one, or 0.
count_of() {
  case $1 in
    '' | *[!0-9]*) printf '0' ;;
    *)
      number=${1#"${1%%[!0]*}"}
      printf '%s' "${number:-0}"
      ;;
  esac
}

# Reads a `@heeler-status` value into s_state, s_app, s_turn and s_blocked.
read_status() {
  s_state= s_app= s_turn=0 s_blocked=0
  saved_ifs=$IFS
  IFS=:
  set -f
  # shellcheck disable=SC2086 # the words are the point
  set -- $1
  set +f
  IFS=$saved_ifs
  for word in "$@"; do
    case $word in
      *=*) ;;
      *) continue ;;
    esac
    case ${word%%=*} in
      state) s_state=${word#*=} ;;
      app) s_app=${word#*=} ;;
      turn) s_turn=$(count_of "${word#*=}") ;;
      blocked) s_blocked=$(count_of "${word#*=}") ;;
    esac
  done
}

reports_done() {
  for reporter in $DONE_REPORTERS; do
    [ "$reporter" = "$1" ] && return 0
  done
  return 1
}

# What `@heeler-status` holds after a report of `state` from `app`, with an
# optional `kind` and base64 `msg`, continuing the counts of `previous`: a turn
# ends when done or error follows working or blocked, or idle follows working
# for a program not known to report done, and each entry into blocked is one
# more question. A report from another program than the last ends nothing of its.
continue_status() {
  read_status "$1"
  state=$2 app=$3 kind=${4-} msg=${5-}
  if [ "$state" = clear ]; then
    printf 'turn=%s:blocked=%s\n' "$s_turn" "$s_blocked"
    return
  fi
  same=0
  [ -n "$s_state" ] && [ "$s_app" = "$app" ] && same=1
  turn=$s_turn
  if [ "$same" = 1 ]; then
    case $s_state:$state in
      working:done | working:error | blocked:done | blocked:error) turn=$((turn + 1)) ;;
      working:idle) reports_done "$app" || turn=$((turn + 1)) ;;
    esac
  fi
  blocked=$s_blocked
  if [ "$state" = blocked ] && ! { [ "$same" = 1 ] && [ "$s_state" = blocked ]; }; then
    blocked=$((blocked + 1))
  fi
  words="state=$state:app=$app"
  [ -z "$kind" ] || words="$words:kind=$kind"
  [ -z "$msg" ] || words="$words:msg=$msg"
  printf '%s:turn=%s:blocked=%s\n' "$words" "$turn" "$blocked"
}

# The directory Heeler keeps its own files in: Application Support on a Mac,
# whatever `XDG_DATA_HOME` says, as the Host Helper's install has it.
data_home() {
  [ -n "${HOME-}" ] || return 1
  case $(uname -s) in
    Darwin) printf '%s\n' "$HOME/Library/Application Support" ;;
    *)
      case ${XDG_DATA_HOME-} in
        /*) printf '%s\n' "$XDG_DATA_HOME" ;;
        *) printf '%s\n' "$HOME/.local/share" ;;
      esac
      ;;
  esac
}

# A path with its folder's links resolved.
resolved() {
  folder=$(cd -P -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$folder" "${1##*/}"
}

# The tmux the app stored for the server on `socket` (the Helper's
# `tmux/<socket name>/paths.json`, the executable and socket of `TmuxPaths`),
# or nothing when it stored none, or stored another server's.
stored_tmux() {
  data=$(data_home) || return 1
  file="$data/heeler/host-helper/tmux/${1##*/}/paths.json"
  [ -r "$file" ] || return 1
  stored_executable= stored_socket=
  while IFS="$(printf '\t')" read -r key value; do
    case $key in
      executable) stored_executable=$(json_text "$value") ;;
      socket) stored_socket=$(json_text "$value") ;;
    esac
  done <<EOF
$(awk -v want="executable socket" -v stop="" "$JSON_MEMBERS" <"$file")
EOF
  case $stored_executable in
    /*) ;;
    *) return 1 ;;
  esac
  [ -n "$stored_socket" ] || return 1
  [ "$(resolved "$stored_socket")" = "$(resolved "$1")" ] || return 1
  printf '%s\n' "$stored_executable"
}

# What the app's process reader reads for a process's start (ADR 0034).
process_start() {
  case $(uname -s) in
    Linux)
      stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
      # The command name may hold spaces and parentheses; the last ") " ends it.
      fields=${stat##*') '}
      set -f
      # shellcheck disable=SC2086 # the fields after the command name
      set -- $fields
      set +f
      [ "$#" -ge 20 ] || return 1
      shift 19
      case $1 in
        '' | *[!0-9]*) return 1 ;;
      esac
      printf '%s\n' "$1"
      ;;
    *)
      start=$(TZ=UTC /bin/ps -o lstart= -p "$1" 2>/dev/null) || return 1
      start=${start#"${start%%[! ]*}"}
      start=${start%"${start##*[! ]}"}
      [ -n "$start" ] || return 1
      printf '%s\n' "$start"
      ;;
  esac
}

# Characters a value may hold to sit in a tmux format and command unquoted.
plain_value() {
  case $1 in
    *[!A-Za-z0-9=:+/._\ -]*) return 1 ;;
  esac
  return 0
}

hook() {
  payload=$(cat) || return
  pane=${TMUX_PANE-}
  case $pane in
    %*) ;;
    *) return ;;
  esac
  case ${pane#%} in
    '' | *[!0-9]*) return ;;
  esac
  # `TMUX` is `<socket>,<server pid>,<session>`, and a socket may hold commas.
  environment=${TMUX-}
  socket=${environment%,*,*}
  [ "$socket" != "$environment" ] || return
  server_pid=${environment#"$socket",}
  server_pid=${server_pid%%,*}
  case $socket in
    /*) ;;
    *) return ;;
  esac
  case $server_pid in
    '' | *[!0-9]*) return ;;
  esac
  tmux=$(stored_tmux "$socket") || return

  event= source= notification= tool= input= session= transcript= message=
  while IFS="$(printf '\t')" read -r key value; do
    case $key in
      hook_event_name) event=$(json_text "$value") ;;
      source) source=$(json_text "$value") ;;
      notification_type) notification=$(json_text "$value") ;;
      tool_name) tool=$value ;;
      tool_input) input=$value ;;
      session_id) session=$value ;;
      transcript_path) transcript=$value ;;
      last_assistant_message) message=$value ;;
    esac
  done <<EOF
$(printf '%s\n' "$payload" | awk -v want="hook_event_name source notification_type tool_name tool_input session_id transcript_path last_assistant_message" -v stop="tool_response" "$JSON_MEMBERS")
EOF

  # The word this event reports, and what it does to the open questions.
  report= kind= msg= settles= asks=
  case $event in
    SessionStart)
      case $source in
        startup | resume | clear) report=idle ;;
      esac
      ;;
    UserPromptSubmit) report=working settles=1 ;;
    PreToolUse) report=working ;;
    PostToolUse | PostToolUseFailure) report=working ;;
    PermissionRequest) report=blocked kind=permission asks=tool ;;
    Notification)
      case $notification in
        permission_prompt) report=blocked kind=permission asks=u ;;
        idle_prompt) report=idle ;;
      esac
      ;;
    Stop) report=done settles=1 ;;
    StopFailure) report=error settles=1 msg=$(status_message "$message") ;;
    SessionEnd) report=clear settles=1 ;;
  esac
  question=
  case $event in
    PermissionRequest | PostToolUse | PostToolUseFailure)
      question=$(printf '%s\n%s' "$tool" "$input" | cksum | awk '{ print $1 "-" $2 }')
      ;;
  esac
  [ "$asks" = u ] && question=u

  claude=$PPID
  attempt=0
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    read=$("$tmux" -N -S "$socket" display-message -p -t "$pane" \
      "#{pid}$SEP#{pane_tty}$SEP#{$STATUS_OPTION}$SEP#{$ASK_OPTION}$SEP#{$SESSION_OPTION}" 2>/dev/null) || return
    IFS=$SEP read -r live_pid pane_tty status open saved_session <<EOF
$read
EOF
    [ "$live_pid" = "$server_pid" ] || return
    if [ "$attempt" = 1 ]; then
      # Only the Claude Code that leads the foreground of the Pane's own
      # terminal: not a `claude -p` a tool started, nor one in a terminal of
      # its own inside the Pane.
      set -f
      # shellcheck disable=SC2046 # three fields
      set -- $(ps -o pgid= -o tpgid= -o tty= -p "$claude" 2>/dev/null)
      set +f
      [ "${1-}" = "$claude" ] && [ "${2-}" = "$claude" ] && [ "/dev/${3-}" = "$pane_tty" ] || return
      write_session
    fi
    [ -n "$report" ] || return

    # Once blocked, only the asking tool's answer, a turn's start or end, the
    # session's end or Heeler moves the status: a subagent's or a parallel
    # tool's events do not hide the question.
    read_status "$status"
    holding=
    if [ "$s_state" = blocked ] && [ "$s_app" = "$APP" ]; then
      set -f
      # shellcheck disable=SC2086 # the asker and its questions
      set -- $open
      set +f
      [ "${1-}" = "$claude" ] && holding=1
    fi
    next=$status
    next_open=$open
    if [ -n "$settles" ] || [ -z "$holding" ]; then
      next=$(continue_status "$status" "$report" "$APP" "$kind" "$msg")
      if [ "$report" = blocked ]; then next_open="$claude $question"; else next_open=; fi
    elif [ "$report" = blocked ] && [ "$asks" = tool ]; then
      next_open="$open $question"
    elif [ "$event" = PostToolUse ] || [ "$event" = PostToolUseFailure ]; then
      shift
      remaining= answered=
      for entry in "$@"; do
        if [ -z "$answered" ] && [ "$entry" = "$question" ]; then answered=1; else remaining="$remaining $entry"; fi
      done
      [ -n "$answered" ] || return
      if [ -n "$remaining" ]; then
        next_open="$claude$remaining"
      else
        next=$(continue_status "$status" working "$APP")
        next_open=
      fi
    else
      return
    fi
    [ "$next" != "$status" ] || [ "$next_open" != "$open" ] || return

    if plain_value "$status" && plain_value "$open"; then
      # Written only while the Pane still holds what was read, so a hook
      # running alongside cannot undo this one, nor this one it.
      result=$("$tmux" -N -S "$socket" \
        if-shell -F -t "$pane" "#{&&:#{==:#{$STATUS_OPTION},$status},#{==:#{$ASK_OPTION},$open}}" \
        "set-option -p -t '$pane' $STATUS_OPTION '$next' ; set-option -p -t '$pane' $ASK_OPTION '$next_open'" \
        \; display-message -p -t "$pane" "#{$STATUS_OPTION}$SEP#{$ASK_OPTION}" 2>/dev/null) || return
      [ "$result" = "$next$SEP$next_open" ] && return
    else
      "$tmux" -N -S "$socket" set-option -p -t "$pane" "$STATUS_OPTION" "$next" \; \
        set-option -p -t "$pane" "$ASK_OPTION" "$next_open" >/dev/null 2>&1
      return
    fi
  done
}

# The session Chat verifies (ADR 0034): its id, its Transcript, and this
# Claude Code's pid and start. Written when it names another session or process.
write_session() {
  [ -n "$session" ] || return 0
  [ "$event" != SessionEnd ] || return 0
  value="{\"session\":$session"
  [ -z "$transcript" ] || value="$value,\"file\":$transcript"
  value="$value,\"pid\":$claude"
  case $saved_session in
    "$value,"* | "$value}") return 0 ;;
  esac
  start=$(process_start "$claude") && value="$value,\"start\":\"$start\""
  "$tmux" -N -S "$socket" set-option -p -t "$pane" "$SESSION_OPTION" "$value}" >/dev/null 2>&1
  return 0
}

if [ "${1-}" = continue ]; then
  shift
  continue_status "$@"
  exit 0
fi
hook
exit 0
