#!/bin/zsh
# watchconnectivity.sh — WatchConnectivity between SimRun's iPhone and Apple Watch (docs/pairing.md): runs WCPhone, whose
# Watch app WCWatch comes along on the paired watch, waits until each side sees the other, then sends a message (and
# its reply), the application context and user info each way and checks they arrive. Exits 1 at the first step that
# fails. Needs `make test-apps` and a watchOS runtime; uses the simrun next to this checkout's build unless SIMRUN is set.
#
#   tests/scripts/watchconnectivity.sh
cd "${0:A:h}/../.." || exit 2
SIMRUN=${SIMRUN:-build/bin/simrun}
fail() { echo "FAIL $*"; $SIMRUN quit WCPhone >/dev/null 2>&1; $SIMRUN quit WCWatch >/dev/null 2>&1; exit 1; }
ok() { echo "ok  $*"; }
# eval a script in an app; its value (what it returns). On the watch, `show(name)` first turns the Crown from the top of the list until an
# element with that name or identifier is there: a watch list only has the rows on screen.
SHOW='const show = async name => { try { await app.crown(-2000); } catch (e) { return; }   /* an iPhone app: no Crown */
  for (let i = 0; i < 20; i++) { if ((await app.ax.elements()).some(e => e.name === name || e.id === name)) return; await app.crown(40); } };'
js() { $SIMRUN eval "$1" "$SHOW $2" 2>&1 | tail -1; }
received() { js "$1" "await show('received'); return await app.getByTestId('received').text();"; }

$SIMRUN quit WCPhone >/dev/null 2>&1; $SIMRUN quit WCWatch >/dev/null 2>&1
$SIMRUN run --headless "$PWD/build/apps/WCPhone.app" >/dev/null 2>&1 &

# both sides activated and reachable: paired, each app installed and running on its device (pairing takes ~10 s the
# first time the watch comes up)
for side in WCPhone WCWatch; do
  for i in {1..120}; do
    r=$(js $side "await show('reachable'); return await app.getByTestId('reachable').text();")
    [[ $r == "Reachable, yes" || $r == reachable ]] && break
    (( i == 120 )) && fail "$side never became reachable"
    sleep 1
  done
done
ok "both sides reachable"

# send from `from` with its `button`; `to` must show `want` (and `from` `reply`, for a message)
check() {
  local from=$1 button=$2 to=$3 want=$4 reply=$5
  js $from "await show('$button'); await app.getByRole('button', { name: '$button' }).tap(); 1" >/dev/null
  for i in {1..20}; do [[ $(received $to) == *"$want"* ]] && break; sleep 0.5; done
  [[ $(received $to) == *"$want"* ]] || fail "$from $button: $to shows $(received $to), not $want"
  if [[ -n $reply ]]; then
    for i in {1..20}; do [[ $(received $from) == *"$reply"* ]] && break; sleep 0.5; done
    [[ $(received $from) == *"$reply"* ]] || fail "$from $button: no reply ($(received $from))"
  fi
  ok "$from → $to: $button"
}
check WCPhone "Send Message" WCWatch "message: message 1" "reply: reply to message 1"
check WCWatch "Send Message" WCPhone "message: message 1" "reply: reply to message 1"
check WCPhone "Update Context" WCWatch "context: context 2"
check WCWatch "Update Context" WCPhone "context: context 2"
check WCPhone "Transfer User Info" WCWatch "user info: user info 3"
check WCWatch "Transfer User Info" WCPhone "user info: user info 3"

$SIMRUN quit WCPhone >/dev/null 2>&1; $SIMRUN quit WCWatch >/dev/null 2>&1
echo "all passed"
