# Cubacadabra iOS demo

The app loads `first-game` from the same package served by the web host:

```text
http://localhost:5173/games/first-game/manifest.json
http://localhost:5173/games/first-game/game.luau
```

Swift is the platform adapter: it fetches the package, owns the touch controls,
and hosts the `MTKView`. The Rust static library owns simulation, Luau
execution, and the Metal/wgpu renderer. This keeps game logic portable and
avoids maintaining a second Luau VM in Swift. Start the web dev server from
`../web` before running the app in Simulator. A physical device needs the
Mac's LAN address instead of `localhost`.
