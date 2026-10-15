#!/bin/bash
# Stand-in for the NDI Discovery Server, for trying the app without the SDK.
# In the app: "Choose NDI Server Location…" and pick this file.
echo "fake NDI discovery server listening on 5959"
trap 'exit 0' TERM
nc -lk 5959 >/dev/null 2>&1 &
NC=$!
trap 'kill $NC 2>/dev/null; exit 0' TERM INT
wait $NC
