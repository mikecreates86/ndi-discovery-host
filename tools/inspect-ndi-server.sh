#!/bin/bash
# Read-only probe of the real NDI Discovery Server. Run it in Terminal on the Mac
# (stop the app's server first: menu > Stop Server) and send the output to Casey.
# It runs the server for about 6 seconds, then stops it. It changes no settings.
BIN="${1:-/Library/NDI SDK for Apple/bin/Application.Mac.NDI.DirectoryService}"

echo "== file =="; ls -l "$BIN" || exit 1
file "$BIN"
echo "quarantine: $(xattr -p com.apple.quarantine "$BIN" 2>/dev/null || echo none)"

echo; echo "== --help (3s limit) =="
"$BIN" --help </dev/null 2>&1 & P=$!
sleep 3; kill $P 2>/dev/null; wait $P 2>/dev/null; echo "(exit $?)"

echo; echo "== run with no terminal (stdin from /dev/null, output piped) =="
OUT=$(mktemp)
"$BIN" </dev/null >"$OUT" 2>&1 & P=$!
sleep 6
if kill -0 $P 2>/dev/null; then
  echo "still running after 6s: yes (pid $P)"
  echo "-- listening sockets --"
  lsof -nP -a -p $P -iTCP -sTCP:LISTEN 2>&1
  lsof -nP -a -p $P -iUDP 2>&1
  echo "-- SIGTERM test --"
  START=$(date +%s); kill -TERM $P
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 $P 2>/dev/null || break; sleep 0.5; done
  if kill -0 $P 2>/dev/null; then echo "did NOT exit within 5s of SIGTERM"; kill -KILL $P
  else wait $P; echo "exited after SIGTERM in about $(( $(date +%s) - START ))s, exit code $?"; fi
else
  wait $P; echo "exited on its own, code $? (a TTY may be required, or the port is in use)"
fi
echo; echo "== output =="; cat "$OUT"; rm -f "$OUT"
