#!/usr/bin/env bash

# Shared shell helpers for VM automation scripts.
#
# These functions wrap the tmux interactions used by the VM automation flow so
# the calling scripts can express higher-level intent like "wait for login
# prompt" instead of repeating pane-capture details.

# Capture recent output from a tmux pane.
#
# Args:
#   $1: tmux pane target, for example "session:window" or "session:window.pane"
#   $2: optional number of recent visible lines to capture; 0 captures the full
#       visible pane instead of a tail region
# Returns:
#   Writes the captured pane contents to stdout.
tmux_capture_recent_output() {
  local pane_target="$1"
  local num_lines="${2:-20}"
  local pane_height
  local start_line

  if [[ "$num_lines" -eq 0 ]]; then
    tmux capture-pane -p -J -t "$pane_target" | tr -d '\r'
    return 0
  fi

  pane_height=$(tmux display -p -t "$pane_target" '#{pane_height}')
  start_line=$((pane_height - num_lines))
  tmux capture-pane -p -S "$start_line" -E - -t "$pane_target" | tr -d '\r'
}

# Capture scrollback from a tmux pane starting at a given line offset.
#
# Args:
#   $1: tmux pane target
#   $2: optional starting line offset passed to `tmux capture-pane -S`; defaults
#       to -200 to include recent scrollback
# Returns:
#   Writes the captured scrollback text to stdout.
tmux_capture_scrollback() {
  local pane_target="$1"
  local start_line="${2:--200}"

  tmux capture-pane -p -S "$start_line" -t "$pane_target"
}

# Poll a tmux pane until literal text appears.
#
# Matching is case-insensitive and uses fixed-string search, which is useful for
# prompts or markers that should not be treated as regular expressions.
#
# Args:
#   $1: tmux pane target
#   $2: text to search for
#   $3: start timestamp in epoch seconds, used only for progress logging
#   $4: optional number of recent lines to scan on each poll; 0 scans the full
#       visible pane
#   $5: optional poll interval in seconds
# Returns:
#   Exits with status 0 once the text is observed.
wait_for_text() {
  local pane_target="$1"
  local text="$2"
  local start_time_s="$3"
  local num_lines="${4:-20}"
  local delay_s="${5:-1}"
  local timeout_s="${6:-0}"
  local output
  local now
  local wait_started_s

  echo "[*] Waiting for text: $text"
  wait_started_s=$(date +%s)
  while true; do
    now=$(date +%s)
    output=$(tmux_capture_recent_output "$pane_target" "$num_lines")
    if echo "$output" | grep -Fqi "$text"; then
      echo "[*] Found text: $text +$((now - start_time_s)) seconds"
      return 0
    fi
    if (( timeout_s > 0 && now - wait_started_s >= timeout_s )); then
      echo "[!] Timed out waiting for text: $text after ${timeout_s}s" >&2
      return 1
    fi
    sleep "$delay_s"
  done
}

# Poll a tmux pane until a prompt regex matches, then send input followed by
# Enter.
#
# Matching is case-insensitive and uses extended regular expressions so callers
# can wait on flexible prompts such as cloud-init status lines.
#
# Args:
#   $1: tmux pane target
#   $2: case-insensitive extended regex to match
#   $3: input to send once matched
#   $4: start timestamp in epoch seconds, used only for progress logging
#   $5: optional number of recent lines to scan; 0 scans the full visible pane
#   $6: optional poll interval in seconds
# Returns:
#   Exits with status 0 once the regex matches and the input has been sent.
wait_for_prompt_and_send() {
  local pane_target="$1"
  local prompt="$2"
  local input="$3"
  local start_time_s="$4"
  local num_lines="${5:-10}"
  local delay_s="${6:-1}"
  local timeout_s="${7:-0}"
  local output
  local now
  local wait_started_s

  echo "[*] Waiting for prompt: $prompt"
  wait_started_s=$(date +%s)
  while true; do
    now=$(date +%s)
    output=$(tmux_capture_recent_output "$pane_target" "$num_lines")
    if echo "$output" | grep -qiE "$prompt"; then
      echo "[*] Sending input for prompt: $prompt +$((now - start_time_s)) seconds"
      tmux send-keys -t "$pane_target" "$input" Enter
      return 0
    fi
    if (( timeout_s > 0 && now - wait_started_s >= timeout_s )); then
      echo "[!] Timed out waiting for prompt: $prompt after ${timeout_s}s" >&2
      return 1
    fi
    sleep "$delay_s"
  done
}
