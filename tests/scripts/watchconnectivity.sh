#!/bin/zsh
# watchconnectivity.sh — WatchConnectivity between SimRun's iPhone and Apple Watch (docs/pairing.md): runs WCPhone with
# its Watch app WCWatch on the paired watch (--with-watch-app), waits until each side sees the other, checks the
# session's state, then sends each way a message and message data (and their replies), the application context, user
# info and a file, and checks each arrives; last, the context the iPhone sets while the watch app isn't running reaches
# it when it starts. Exits 1 at the first step that fails. Needs `make test-apps` and a watchOS runtime; uses the
# simrun next to this checkout's build unless SIMRUN is set.
#
#   tests/scripts/watchconnectivity.sh
#
# Every payload is new ("<what> <n> #<tag>", the tag new each launch; tests/apps/wcphone/Session.swift): a run checks
# for exactly what it sent, so nothing from an earlier run or step counts, and WatchConnectivity, which drops an
# application context equal to the last one sent, delivers each one.
cd "${0:A:h}/../.." || exit 2
SIMRUN=${SIMRUN:-build/bin/simrun}
WATCH_APP="$PWD/build/apps/WCPhone.app/Watch/WCWatch.app"
quit() { $SIMRUN quit WCPhone >/dev/null 2>&1; $SIMRUN quit WCWatch >/dev/null 2>&1; }
fail() { echo "FAIL $*"; quit; exit 1; }
ok() { echo "ok  $*"; }
# eval a script in an app; its value (what it returns). On the watch, `show(name)` first turns the Crown from the top of the list until an
# element with that name or identifier is there: a watch list only has the rows on screen.
SHOW='const show = async name => { try { await app.crown(-2000); } catch (e) { return; }   /* an iPhone app: no Crown */
  for (let i = 0; i < 20; i++) { if ((await app.ax.elements()).some(e => e.name === name || e.id === name)) return; await app.crown(40); } };'
js() { $SIMRUN eval "$1" "$SHOW $2" 2>&1 | tail -1; }
text() { js $1 "await show('$2'); return await app.getByTestId('$2').text();"; }
# whether app $1 received the line $2 ("<kind>: <payload>") in this launch
received() { [[ $(js $1 "await show('received'); return (await app.getByTestId('received').value()).split('\n').includes('$2');") == true ]]; }
# wait up to 30 s for app $1 to receive the line $2
await_line() { for i in {1..60}; do received $1 "$2" && return 0; sleep 0.5; done; return 1; }
history() { js $1 "await show('received'); return (await app.getByTestId('received').value()).split('\n').join(' | ');"; }
# tap button $2 in app $1; prints the payload it sent
send() {
  local before=$(text $1 sent) after
  js $1 "await show('$2'); await app.getByRole('button', { name: '$2' }).tap(); 1" >/dev/null
  for i in {1..20}; do after=$(text $1 sent); [[ $after != $before ]] && break; sleep 0.25; done
  [[ $after != $before && $after == *' #'* ]] || { echo "FAIL $1 $2: nothing sent (sent shows $after)" >&2; return 1; }
  echo $after
}
# from $1 to $2 with button $3: $2 receives "<kind $4>: <payload>", and $1 "<kind $5>: reply to <payload>" if $5 is given
check() {
  local from=$1 to=$2 button=$3 kind=$4 reply=$5 p
  p=$(send $from $button) || { quit; exit 1; }
  local want="$kind: $p"
  [[ $kind == file ]] && want="file: $p (metadata $p)"
  await_line $to "$want" || fail "$from $button: $to never got \"$want\" (got: $(history $to))"
  [[ -z $reply ]] || await_line $from "$reply: reply to $p" || fail "$from $button: no \"$reply: reply to $p\" (got: $(history $from))"
  ok "$from → $to: $button ($p)"
}

quit
$SIMRUN run --headless --with-watch-app "$PWD/build/apps/WCPhone.app" >/dev/null 2>&1 &

# both sides activated and reachable: paired, each app installed and running on its device (pairing takes ~10 s the
# first time the watch comes up)
for side in WCPhone WCWatch; do
  for i in {1..120}; do
    r=$(text $side reachable)
    [[ $r == "Reachable, yes" || $r == reachable ]] && break
    (( i == 120 )) && fail "$side never became reachable"
    sleep 1
  done
done
ok "both sides reachable"
[[ $(text WCPhone paired) == "Paired, yes" ]] || fail "WCPhone: not paired ($(text WCPhone paired))"
[[ $(text WCPhone installed) == "Watch app installed, yes" ]] || fail "WCPhone: watch app not installed ($(text WCPhone installed))"
[[ $(text WCWatch installed) == "iPhone app installed" ]] || fail "WCWatch: iPhone app not installed ($(text WCWatch installed))"
ok "paired, both apps installed"

for from to in WCPhone WCWatch WCWatch WCPhone; do
  check $from $to "Send Message" message reply
  check $from $to "Send Data" data "data reply"
  check $from $to "Update Context" context
  check $from $to "Transfer User Info" "user info"
  check $from $to "Transfer File" file
done

# the context set while the watch app isn't running: it has it when it starts (as its delegate's context, or stored)
$SIMRUN quit WCWatch >/dev/null 2>&1
for i in {1..20}; do [[ $(text WCPhone reachable) == "Reachable, no" ]] && break; sleep 0.5; done
p=$(send WCPhone "Update Context") || { quit; exit 1; }
$SIMRUN run --headless "$WATCH_APP" >/dev/null 2>&1 &
got=
for i in {1..60}; do received WCWatch "context: $p" || received WCWatch "stored context: $p" && { got=1; break; }; sleep 0.5; done
[[ -n $got ]] || fail "WCWatch, started after the context: never got \"$p\" (got: $(history WCWatch))"
ok "WCPhone → WCWatch (not running): Update Context ($p)"

quit
echo "all passed"
