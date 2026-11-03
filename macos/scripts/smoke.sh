#!/bin/zsh
# Smoke test for Bookshelf.app (docs/MACOS_APP.md §20). It uses a fake `claude` that never
# answers and never calls a model; the real one is never run. Postgres is started when
# needed and never stopped.
#
#   macos/scripts/smoke.sh [--no-build]
#
# Every launch goes through `env -i … open -n`, as from Finder: no terminal variables.
#   quit    twice: start, show the page, press ⌘Q (--smoke). The second (warm) launch must
#           show the page within 5 s; nothing may be left on 8000/4321, no guard, no claude.
#   kill    start, open a /search/answer on the fake claude, SIGKILL the app (Force Quit).
#           8000/4321 must be free within 1 s; no claude and no guard may be left after.
#           Launched with CLAUDECODE=1 and AI_AGENT set: the services must not get them.
#   sigint  start, open a /search/answer on the fake claude, quit (SIGTERM → ⌘Q). The API's
#           guard must need its SIGINT step (5 s on); no claude may be left after.
setopt err_exit pipe_fail
zmodload zsh/datetime

MACOS="${0:A:h:h}"
APP="$MACOS/build/Bookshelf.app"
BIN="$APP/Contents/MacOS/Bookshelf"
SUPPORT="$HOME/Library/Application Support/Bookshelf"
LOGS="$HOME/Library/Logs/Bookshelf"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bookshelf-smoke.XXXXXX")"
FAKE="$WORK/claude"
FAILED=0
typeset -a RESULTS

[[ "${1:-}" == "--no-build" ]] || "$MACOS/scripts/build-app.sh" >/dev/null

# ---- helpers ---------------------------------------------------------------------------

now() { print -r -- "$EPOCHREALTIME"; }
elapsed() { printf '%.3f' $(( $2 - $1 )); }
listening() { lsof -nP -iTCP:8000 -iTCP:4321 -sTCP:LISTEN -Fpc 2>/dev/null | sed -n 's/^c//p' | sort -u | tr '\n' ' '; }
guards() { pgrep -f "$BIN --guard" || true; }
fakes() { pgrep -f "$FAKE" || true; }
app_pid() { pgrep -f -- "--smoke-report $1" | head -1 || true; }
report_value() { sed -n "s/^$2=//p" "$1" | tail -1; }

check() {  # check <scenario> <what> <ok?> <detail>
  local mark="ok" detail="${4:-}"
  if [[ "$3" != 1 ]]; then mark="FAIL"; FAILED=1; fi
  RESULTS+=("$(printf '%-7s %-58s %-4s %s' "$1" "$2" "$mark" "$detail")")
  print -r -- "  [$mark] $2${detail:+ ($detail)}"
}

wait_for() {  # wait_for <seconds> <command…>: polls every 20 ms; 0 once the command succeeds
  local deadline=$(( EPOCHREALTIME + $1 )); shift
  until "$@"; do (( EPOCHREALTIME < deadline )) || return 1; sleep 0.02; done
}

has_line() { [[ -f "$1" ]] && grep -q "^$2=" "$1"; }
app_gone() { [[ -z "$(app_pid "$1")" ]]; }
ports_free() { [[ -z "$(listening)" ]]; }
nothing_left() { [[ -z "$(guards)$(fakes)" ]]; }
fake_running() { [[ -n "$(fakes)" ]]; }

launch() {  # launch <report> [env assignments…]: starts the app like Finder does
  local report=$1; shift
  env -i "$@" /usr/bin/open -n "$APP" --args -ClaudeBinary "$FAKE" --smoke-report "$report" ${SMOKE_FLAG:-}
}

# The page is up, and the services got the fake claude: never send a question otherwise.
wait_shown() {  # wait_shown <scenario> <report> → sets PID
  if ! wait_for 60 has_line "$2" shown; then
    check "$1" "page shown" 0 "$(has_line "$2" failed && echo "start failed: see $LOGS/app.log" || echo "timed out")"
    return 1
  fi
  PID="$(app_pid "$2")"
  local api_guard; api_guard="$(cat "$SUPPORT/pids/api.pid")"
  if ! ps -wwE -p "$api_guard" | grep -q "BOOKSHELF_CLAUDE_BIN=$FAKE"; then
    check "$1" "services use the fake claude" 0 "guard $api_guard"
    kill -9 "$PID"; return 1
  fi
}

ask_question() {  # a /search/answer through the web's proxy; the router asks the (fake) model
  curl -sN -X POST http://127.0.0.1:4321/api/search/answer \
    -H 'Content-Type: application/json' -H 'Origin: http://127.0.0.1:4321' \
    -d '{"query":"how do feedback loops and delays shape what I read this year","mode":"auto"}' \
    >"$WORK/answer-$1.out" 2>&1 &
  wait_for 20 fake_running
}

log_since() { tail -c "+$(( $2 + 1 ))" "$1" 2>/dev/null || true; }
size_of() { stat -f %z "$1" 2>/dev/null || echo 0; }

cleanup() {
  local left="$(fakes)"; [[ -z "$left" ]] || kill -9 ${=left} 2>/dev/null || true
  left="$(guards)"; [[ -z "$left" ]] || kill -TERM ${=left} 2>/dev/null || true
  rm -rf "$WORK"
}

# ---- preconditions ---------------------------------------------------------------------

cat >"$FAKE" <<'FAKE'
#!/bin/sh
# Fake claude for the Bookshelf smoke test: answers --version, otherwise hangs and never
# calls a model. Its path is unique, so the test can find every copy that is still alive.
[ "${1:-}" = "--version" ] && { echo "0.0.0 (fake claude)"; exit 0; }
while :; do sleep 1; done
FAKE
chmod +x "$FAKE"

if pgrep -fl "Bookshelf.app/Contents/MacOS/Bookshelf" | grep -q .; then
  print -u2 "Bookshelf (or one of its guards) is running; quit it first."; rm -rf "$WORK"; exit 2
fi
if [[ -n "$(listening)" ]]; then
  print -u2 "Something listens on 8000 or 4321 ($(listening)); stop it first."; rm -rf "$WORK"; exit 2
fi
trap cleanup EXIT  # from here on, every guard and fake claude is this run's
print "Bookshelf smoke test — app $APP, fake claude $FAKE"

# ---- quit: ⌘Q after the page is shown, twice (cold, then warm) ----------------------------

SMOKE_FLAG=--smoke
for round in 1 2; do
  report="$WORK/quit-$round.txt"
  print "quit #$round"
  t0=$(now)
  launch "$report"
  if wait_for 60 has_line "$report" shown; then
    shown=$(elapsed "$t0" "$(now)")
    if (( round == 2 )); then
      check quit "warm launch shows the page within 5 s (from open -n)" $(( shown <= 5.0 )) "${shown} s; app: ready $(report_value "$report" ready) s, shown $(report_value "$report" shown) s"
    else
      print "  first launch: page shown ${shown} s after open -n"
    fi
  else
    check quit "page shown (round $round)" 0 "$(has_line "$report" failed && echo "start failed" || echo "timed out")"
    continue
  fi
  wait_for 15 app_gone "$report" || true
  check quit "⌘Q quits the app (round $round)" $(app_gone "$report" && echo 1 || echo 0) "quit $(report_value "$report" quit) s → stopped $(report_value "$report" stopped) s"
  check quit "nothing on 8000/4321 once the app is gone (round $round)" $(ports_free && echo 1 || echo 0) "$(listening)"
  check quit "no guard and no claude left (round $round)" $(nothing_left && echo 1 || echo 0) "$(guards) $(fakes)"
done
SMOKE_FLAG=

# ---- kill: Force Quit with a question open ----------------------------------------------

print "kill"
report="$WORK/kill.txt"
launch "$report" CLAUDECODE=1 AI_AGENT=bookshelf-smoke
if wait_shown kill "$report"; then
  api_guard="$(cat "$SUPPORT/pids/api.pid")"
  app_env="$(ps -wwE -p "$PID" -o command=)"
  guard_env="$(ps -wwE -p "$api_guard" -o command=)"
  if [[ "$app_env" == *CLAUDECODE=1* ]]; then
    check kill "allowlist: the app got CLAUDECODE, its services did not" $([[ "$guard_env" != *CLAUDECODE=* && "$guard_env" != *AI_AGENT=* ]] && echo 1 || echo 0)
  else
    check kill "allowlist: the services got no CLAUDECODE / AI_AGENT" $([[ "$guard_env" != *CLAUDECODE=* && "$guard_env" != *AI_AGENT=* ]] && echo 1 || echo 0) "open passed none to the app"
  fi
  mark=$(size_of "$LOGS/api.log")
  if ask_question kill; then
    sleep 1  # a settled request: uvicorn waits for it, as it would for a long answer
    t0=$(now)
    kill -9 "$PID"
    wait_for 5 ports_free || true
    freed=$(elapsed "$t0" "$(now)")
    check kill "kill -9: 8000/4321 free within 1 s" $(( freed <= 1.0 )) "${freed} s; left: $(listening)"
    wait_for 10 nothing_left || true
    done_at=$(elapsed "$t0" "$(now)")
    (( $(size_of "$LOGS/api.log") >= mark )) || mark=0
    step="$(log_since "$LOGS/api.log" "$mark" | grep '\[guard.*stopped' | sed 's/.*\] //' | tail -1)"
    check kill "kill -9: no claude and no guard left" $(nothing_left && echo 1 || echo 0) "all gone after ${done_at} s; API guard: ${step:-?}; left: $(guards) $(fakes)"
  else
    check kill "the question reached the fake claude" 0 "see $WORK/answer-kill.out"
    kill -9 "$PID"
  fi
fi
wait_for 10 nothing_left || true

# ---- sigint: quit with a question open; the guard must need SIGINT ------------------------

print "sigint"
report="$WORK/sigint.txt"
api_log="$LOGS/api.log"
mark=$(size_of "$api_log")
launch "$report"
if wait_shown sigint "$report"; then
  if ask_question sigint; then
    t0=$(now)
    kill -TERM "$PID"  # the app's handler presses ⌘Q
    wait_for 15 app_gone "$report" || true
    took=$(elapsed "$t0" "$(now)")
    (( $(size_of "$api_log") >= mark )) || mark=0  # rotated at launch
    stop_log="$(log_since "$api_log" "$mark" | grep '\[guard' || true)"
    check sigint "quit with a question open ends the app" $(app_gone "$report" && echo 1 || echo 0) "${took} s"
    check sigint "the API's guard needed SIGINT (5 s on)" $([[ "$stop_log" == *": SIGINT"* ]] && echo 1 || echo 0) "$(print -r -- "$stop_log" | grep -E 'stopped|SIGINT' | sed 's/.*\] //' | tr '\n' ';')"
    check sigint "no claude and no guard left" $(nothing_left && echo 1 || echo 0) "$(guards) $(fakes)"
    check sigint "nothing on 8000/4321" $(ports_free && echo 1 || echo 0) "$(listening)"
  else
    check sigint "the question reached the fake claude" 0 "see $WORK/answer-sigint.out"
    kill -TERM "$PID"; wait_for 15 app_gone "$report" || true
  fi
fi

# ---- summary ---------------------------------------------------------------------------

print "\nSummary"
print -l -- $RESULTS
exit $FAILED
