# NDI Discovery Host

A menu bar app that runs the NDI Discovery Server and keeps it running. It replaces the Terminal window you would otherwise leave open. Emmaus Church production network.

It does not include the NDI program. Install the free **NDI SDK for Apple** first. The app uses
`/Library/NDI SDK for Apple/bin/Application.Mac.NDI.DirectoryService`, or any location you pick from the menu.

## READ FIRST: what is and is not verified

This was written on a Linux machine with no Swift compiler and no NDI SDK. So:

| Item | Status |
|---|---|
| Swift code compiles | **NOT verified.** Run `swift build` on the Mac first and fix any typos. |
| Unit tests pass | **NOT run.** Run `swift test`. They use a fake server script, not the real one. |
| Menu bar UI, Launch at Login, sleep prevention, quit dialog | **NOT run.** Needs a look on a real Mac. |
| Fake server script modes and the `ps` output format the stray cleaner reads | Checked in a Linux shell. |
| `tools/inspect-ndi-server.sh` | Tested against the stub only. |
| **NDI server port (5959)** | **UNVERIFIED.** From NDI's published default, not from the binary. |
| **Server arguments** | **UNVERIFIED.** The app passes none. |
| Whether it needs a Terminal (TTY) | **UNVERIFIED.** The app gives it no input and pipes its output. |
| Which network interfaces it listens on | **UNVERIFIED.** The health check connects to `127.0.0.1`. If the server only listens on a specific IP, the check fails and the app will restart a healthy server in a loop. |
| How it reacts to SIGTERM | **UNVERIFIED.** The app sends SIGTERM, then SIGKILL after 3 seconds, which is safe either way. |
| Whether macOS blocks the binary | **UNVERIFIED.** See "If macOS blocks it". |

**Step 1 on the Mac:** stop anything running the server, then run
`tools/inspect-ndi-server.sh` and read the output. It records `--help`, whether it runs without Terminal, the listening port and addresses, and SIGTERM behavior. If the port differs from 5959, change `NDIServer.port` in `Sources/NDIHostCore/NDIServer.swift`. There is deliberately no port setting in the menu until the binary is confirmed to accept one.

Then update this table with what you found.

## Build

```
swift test          # unit tests
./build.sh          # makes build/NDI Discovery Host.app and build/NDI-Discovery-Host-<version>.zip
```

Needs Xcode or the Command Line Tools (`xcode-select --install`). Builds for the chip in the Mac you build on. The version is in the `VERSION` file.

## Install and first run

1. Unzip, drag **NDI Discovery Host** to Applications.
2. The app is only ad-hoc signed, so Gatekeeper will object the first time. **Right-click the app, choose Open, then Open again.** You only do this once.
3. A server icon appears in the menu bar. It also adds itself to Login Items (you may see a macOS notice; allow it in System Settings > General > Login Items).

## The menu

- **Icon:** check mark = running, circling arrows = starting or restarting, octagon with X = not running.
- **Status line:** how long it has been running, or what is wrong in plain words.
- **Address for devices:** click one to copy `IP:port`. Paste it into the NDI Discovery Server field on viewers (or Access Manager) on other VLANs.
- **Restart / Stop / Start Server**, **Launch at Login**, **Keep Mac Awake** (stops the Mac sleeping, the display can still sleep).
- **Open Log Folder**, **Choose NDI Server Location…**, version, **Quit** (asks first, because quitting ends discovery for everyone).

## How it keeps the server alive

- Restarts on any exit after 1, 2, 5, 10, then 30 seconds, forever. 60 seconds of steady running resets the delays.
- Every 10 seconds it tries a TCP connection to the server's port on this Mac. After a 15 second startup grace, 3 failures in a row restarts it, even if the process is still alive.
- If the NDI program is missing it keeps retrying every 30 seconds, so installing the SDK fixes it with no action.
- On launch it stops any leftover copy running from the exact configured path, so the port is free. On quit it stops the server (SIGTERM, then SIGKILL after 3 seconds).
- Only one copy of the app runs.

## If something is wrong

| Symptom | Do this |
|---|---|
| "Not running: NDI server not found" | Install the NDI SDK, or use Choose NDI Server Location… |
| Stuck on "Restarting" | Open Log Folder, read `supervisor.log` (what the app did) and `server.log` (what the NDI server said). |
| Restarts about every 45 seconds but the server seems fine | The port or listening address assumption is wrong. Run `tools/inspect-ndi-server.sh` and see above. |
| Port already in use | Another copy of the server is running (maybe in Terminal). Close it, then Restart Server. |
| Anything else | Quit and reopen the app. |

### If macOS blocks the NDI program
If the log says the program could not be opened, or Gatekeeper shows a warning about it, clear the download flag (this does not modify the program itself):

```
xattr -dr com.apple.quarantine "/Library/NDI SDK for Apple"
```
Admin rights may be needed for that folder. If you can't, open the program once from Finder with right-click > Open.

## Logs

`~/Library/Logs/NDI Discovery Host/` holds `supervisor.log` and `server.log`, each rotating through `.1` and `.2` copies at about 800 KB, about 5 MB total at most.

## Code map (for Casey)

- `Sources/NDIHostCore/Supervisor.swift` all the restart, backoff, and health logic. No UI. Timings are injectable, which is how the tests run in seconds.
- `Health.swift`, `StrayCleaner.swift`, `RotatingLog.swift`, `NetworkInfo.swift`, `ServerState.swift` small single-purpose pieces.
- `Sources/NDIDiscoveryHost/` the menu (`NDIDiscoveryHostApp.swift`) and glue to macOS (`AppModel.swift`).
- `tools/` the SDK probe and a stub server (`fake-ndi-server.sh`, listens on 5959) for trying the app without the SDK.

## Deliberately left out

No port setting, no update checker, no notifications, no analytics, no admin rights, no LaunchDaemon. It never touches the NDI SDK, `~/ndi-config.v1.json`, Access Manager, or network settings. Its only network activity is the local TCP check. Link-local (169.254.x.x) addresses are hidden from the address list because devices can't use them.

## Getting the app without installing developer tools

Pushing this folder to a GitHub repo and running the **Build app** workflow (Actions tab) produces the zip on GitHub's Macs. This workflow has not been run yet. The alternative is `xcode-select --install` on any Mac, then `./build.sh`.
