# Cubacadabra ios app

This is the Swift platform client. It loads a selected game package from a
web host, uses the Rust static library for simulation, Luau execution, and
Metal rendering, and connects to the backend's WebSocket world service for
player presence and movement.

The repositories fit together like this:

```text
game repos  -> src/ + manifest.json (source packages)
rust        -> static library (simulation, scripting host, renderer)
web         -> package host and browser client
backend     -> multiplayer Worker and world WebSockets
ios_app     -> this Swift adapter (touch, lifecycle, MTKView, networking)
```

When starting here, read [rust/README.md](../rust/README.md) next to understand
the library and C ABI, then [first-game/README.md](../first-game/README.md) to
understand the package this app loads. The web server is still required even
when the app itself is the client.

## Run in the iOS Simulator

Check out all repositories as siblings, install the web dependencies, and
start both local services:

```sh
cd ../backend
npm install
npm run dev

cd ../web
npm install
npm run dev
```

Open `ios_app/cubacadabra.xcodeproj` in Xcode, select the shared `cubacadabra`
scheme, choose an iOS Simulator, and Run. The Debug build defaults to:

```text
Game package: http://localhost:5173/games/first-game/
Backend:      ws://localhost:8787
```

The Xcode build phase first builds the default sibling game package through the
shared `tools` repository, stages its runtime
files into `cubacadabra/Resources/`, then compiles the Rust crate for the
selected iOS target and links the resulting static library. You do not need to
build Rust separately for the normal Xcode workflow.

## Run on a physical device over the dev LAN

Start both services on the Mac with LAN binding:

```sh
cd ../backend
npm run dev:lan

cd ../web
npm run dev:lan
```

In the Xcode Run scheme's environment variables, replace the example address
with the Mac's LAN IP:

```text
CUBACADABRA_BACKEND_URL=ws://192.168.1.10:8787
CUBACADABRA_GAME_BASE_URL=http://192.168.1.10:5173/games/first-game/
```

The device and Mac must be on the same network. Local networking is enabled in
the app's `Info.plist`; the Mac may still ask for firewall permission.

## Point the app at production

Release builds default to the deployed services:

```text
Game package: https://cubacadabra.com/games/first-game/
Backend:      wss://cubacadabra.andrew-f97.workers.dev
```

To test production endpoints from a Debug build, keep the Debug scheme and set
the same two environment variables to those values. The app does not need the
local backend or web server in that configuration. Use the Release scheme for
an archive; the Rust build phase compiles the native static library as part of
the Xcode build.

## Code map

- `cubacadabra/GamePackage.swift` — package models, URL defaults, and loader
- `cubacadabra/WorldSocketClient.swift` — world WebSocket and reconnection
- `cubacadabra/EngineBridge.swift` — Swift-to-Rust engine calls
- `cubacadabra/RustGameSurface.swift` — Rust renderer in an `MTKView`
- `cubacadabra/ContentView.swift` — app state, controls, and lifecycle
- `scripts/build_rust_engine.sh` — native Rust build phase invoked by Xcode

## Where to look next

- [rust/README.md](../rust/README.md) — engine and native ABI
- [first-game/README.md](../first-game/README.md) — first-game package schema
- [second-game/README.md](../second-game/README.md) — second-game package behavior
- [backend/README.md](../backend/README.md) — local, LAN, and production sockets
