Yes. You can build an iOS app with **zero Swift and zero SwiftUI**, with essentially all of your application code written in Rust.

The important distinction is that you cannot avoid **iOS frameworks**. Your Rust code still ultimately talks to UIKit, Metal, Core Animation, etc. But Rust can call those frameworks directly through Objective-C bindings.

For something like Cubacadabra, a stack like this is completely viable:

```text
iOS
 ├── Rust
 │    ├── game engine
 │    ├── UI
 │    ├── networking
 │    ├── input
 │    ├── audio
 │    └── app logic
 │
 ├── winit / objc2
 │        ↓
 │      UIKit
 │
 └── wgpu
          ↓
        Metal
```

`winit` already has a native UIKit backend implemented in Rust. Its current iOS code creates UIKit windows/views/controllers and handles the iOS application lifecycle without requiring you to write Swift. ([GitHub][1])

So you can have:

```text
src/
    main.rs
    renderer.rs
    ui.rs
    input.rs
    game.rs

Cargo.toml
Info.plist
Assets.xcassets
```

and **no**:

```text
ContentView.swift
AppDelegate.swift
SceneDelegate.swift
*.storyboard
```

although you'll still need the proper `.app` bundle metadata/resources.

### There's one wrinkle becoming more important

Apple is requiring the **UIScene lifecycle** for apps built with the newest SDK beginning with iOS 27. Apple says apps that don't adopt it will fail to launch. ([Apple Developer][2])

That does **not** mean you need SwiftUI.

It means your Rust app eventually needs to behave roughly like:

```text
UIApplication
      │
      ▼
UIApplicationDelegate
      │
      ▼
UISceneDelegate
      │
      ▼
UIWindowScene
      │
      ▼
UIWindow
      │
      ▼
UIView / CAMetalLayer
```

Those objects can all be created through Rust/Objective-C bindings. UIKit itself is Objective-C-compatible; Swift is not required. Apple still documents the UIKit app lifecycle in Objective-C as well as Swift. ([Apple Developer][3])

For example, crates in the `objc2` ecosystem let Rust effectively do things conceptually equivalent to:

```rust
let window = UIWindow::initWithWindowScene(...);
let controller = UIViewController::new();
window.setRootViewController(Some(&controller));
window.makeKeyAndVisible();
```

Then your `UIView` can expose a `CAMetalLayer`, and `wgpu` renders your entire Cubacadabra interface into it.

### You may still use Xcode

This is another distinction that's easy to miss:

**No Swift/SwiftUI != no Xcode.**

You will probably still use Apple's build/signing infrastructure for:

```text
Rust compilation
      ↓
aarch64-apple-ios binary
      ↓
.app bundle
      ↓
codesign
      ↓
provisioning profile
      ↓
IPA / device / App Store
```

The `winit` maintainers specifically note that iOS still effectively relies on Xcode's infrastructure for bundling, signing, and deploying, even though the application itself can be Rust. ([GitHub][1])

You can automate almost all of that from Cargo/scripts.

### For Cubacadabra, I'd actually favor this

Given that you're building the engine/UI in Rust across:

```text
macOS
Windows
Linux
iOS
Android
Web/WASM
```

I would **not introduce SwiftUI merely because the platform is iOS**.

I'd structure it more like:

```text
                    cubacadabra-core
                           │
                    cubacadabra-ui
                           │
                    cubacadabra-engine
                           │
             ┌─────────────┼─────────────┐
             │             │             │
          desktop         iOS         Android
             │             │             │
           winit          UIKit        Android
             │             │             │
             └────────── wgpu ───────────┘
                         │
                  Metal/Vulkan/etc
```

Then keep a very small:

```text
platform/
    ios/
    macos/
    windows/
    linux/
    android/
```

layer for things that genuinely need OS-specific APIs.

Your iOS platform module might eventually be only a few thousand lines—or considerably less—for things like:

```text
UIApplication/UIScene lifecycle
StoreKit
Sign in with Apple
push notifications
share sheets
camera/photo picker
keyboard behavior
safe areas
clipboard
URL opening
```

Everything else stays Rust.

And there's a nice side effect: this is exactly the direction that helps you avoid the problem we were discussing with your desktop Studio app—**one cross-platform Rust application doesn't have to mean pretending the underlying OS doesn't exist**. You can have 95% shared Rust and a thin native integration layer per platform.

So yes: **a genuine App Store iOS application can be Rust all the way down to the UIKit/Metal boundary, with no SwiftUI and potentially literally zero lines of Swift.**

[1]: https://github.com/rust-windowing/winit/blob/master/winit-uikit/src/lib.rs?utm_source=chatgpt.com "winit/winit-uikit/src/lib.rs at master · rust-windowing/winit · GitHub"
[2]: https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle?changes=_9&language=objc&utm_source=chatgpt.com "Transitioning to the UIKit scene-based life cycle | Apple Developer Documentation"
[3]: https://developer.apple.com/documentation/uikit/uiapplicationdelegate?changes=l___6&language=objc&utm_source=chatgpt.com "UIApplicationDelegate | Apple Developer Documentation"



Alright, now that I've actually looked inside the current repo, here's my take: don't rewrite everything in Rust. But do move more into Rust. Right now the Swift side has grown way past the thin adapter it was supposed to be. The README says iOS handles touch lifecycle, MTKView and networking while Rust owns simulation, Luau and rendering. But files like GamePackage and WorldSocketClient are huge, and implement core Cubacadabra behavior that Android and Desktop will also need. That stuff belongs in Rust. Swift should mostly be UI and Apple integrations. SwiftUI screens, Sign in with Apple or Google, StoreKit down the line, Metal view setup, safe areas, keyboards, that kind of thing. So, the target here isn't zero Swift. It's all domain logic in Rust. That'll also make the Android app much thinner and set you up nicely for desktop.([GitHub][1])([GitHub][2])([GitHub][2])([GitHub][3])([GitHub][4])([GitHub][5])([GitHub][6])([GitHub][7])

[1]: https://github.com/cubacadabra/ios_app "GitHub - cubacadabra/ios_app: Our long-term goal is to build a meaningfully better user-generated gaming platform for creators, children, and parents. · GitHub"
[2]: https://github.com/cubacadabra/ios_app/blob/main/cubacadabra/GamePackage.swift "ios_app/cubacadabra/GamePackage.swift at main · cubacadabra/ios_app · GitHub"
[3]: https://github.com/cubacadabra/ios_app/blob/main/cubacadabra/WorldSocketClient.swift "ios_app/cubacadabra/WorldSocketClient.swift at main · cubacadabra/ios_app · GitHub"
[4]: https://github.com/cubacadabra/ios_app/blob/main/cubacadabra/CubeCatalogService.swift "ios_app/cubacadabra/CubeCatalogService.swift at main · cubacadabra/ios_app · GitHub"
[5]: https://github.com/cubacadabra/ios_app/blob/main/cubacadabra/GameViewModel.swift "ios_app/cubacadabra/GameViewModel.swift at main · cubacadabra/ios_app · GitHub"
[6]: https://github.com/cubacadabra/ios_app/blob/main/cubacadabra/RustGameSurface.swift "ios_app/cubacadabra/RustGameSurface.swift at main · cubacadabra/ios_app · GitHub"
[7]: https://github.com/cubacadabra/ios_app/blob/main/cubacadabra/AccountFlowViews.swift "ios_app/cubacadabra/AccountFlowViews.swift at main · cubacadabra/ios_app · GitHub"




Alright, so after looking at Android and web, this shifts my recommendation pretty strongly. Right now, all three platforms implement their own package loading, websocket world client and state management. That's a red flag. Those are exactly the behaviors that should be identical across all platforms. So, rather than thinking "rewrite Swift in Rust", I think in terms of "pull duplicated game client logic from all three platforms down into Rust." Keep Swift and Kotlin for UI and platform glue, keep JavaScript for DOM and browser specifics, but make Rust the single source of truth for packages, networking protocol, reconnect logic, game state, and rules. That gives you one behavior with three thin shells. So, I wouldn't start a "rewrite Swift/Kotlin in Rust" project per se. I'd start a "pull shared client logic into Rust" project. Then delete code from each app as Rust takes it over. That feels like the high leverage move here.([GitHub][1])([GitHub][2])

[1]: https://github.com/cubacadabra/android_app "GitHub - cubacadabra/android_app: Our long-term goal is to build a meaningfully better user-generated gaming platform for creators, children, and parents. · GitHub"
[2]: https://github.com/cubacadabra/web "GitHub - cubacadabra/web: Our long-term goal is to build a meaningfully better user-generated gaming platform for creators, children, and parents. · GitHub"



Okay, so I couldn't get GitHub search to surface the current Studio source just now. But from what we already know about its architecture, this actually strengthens the case for restructuring the Rust side, not weaken it. It highlights the problem. Right now, if Studio sometimes goes straight to engine internals because the C API isn't quite right, that's a sign that the C API is the wrong seam, not that Studio is special. I'd make the pure Rust API the canonical one. Then have C and WASM bindings as adapters on top. Studio just uses the Rust API directly. That way, Studio stays clean, iOS and Android use the C layer, web uses WASM, and you don't distort the engine around FFI concerns. Also, some of the stuff we


Okay, lemme double check that. You're absolutely right, that was stale. I just pulled the live repo and Studio definitely has real code and lots of commits. And the README confirms exactly what you just described. Studio uses the same engine directly, but it also implements its own package and source loading and its own WebSocket logic. That strengthens the case for pulling shared crates out of all of the clients. Not into the engine crate itself, but alongside it. Think engine, client-core, maybe protocol as separate crates in the same workspace. Then Studio depends on those directly. While iOS/Android go through the C layer and web through WASM. But, make sure the Rust API is the source of truth. And that the C API wraps it, not the other way around. And since Studio's behavior is intentionally different in places, like how it deals with source projects versus consumer packages, not everything should be shared. But the low-level pieces, protocol types, socket plumbing, package formats, those probably should. That's where the win is.([GitHub][1])

[1]: https://github.com/cubacadabra/studio "GitHub - cubacadabra/studio: Our long-term goal is to build a meaningfully better user-generated gaming platform for creators, children, and parents. · GitHub"


I wouldn't put things like the username menu into Rust. That's a platform UI. I think we actually want three layers, engine, client core, and platform UI. The engine is what you already have. Renderer, physics, Luau, simulation. The client core is Rust too. but it's things like package loading, world protocol, networking, state machines, shared models, basically, "this is how Cubacadabra works." Then Swift, Kotlin, and JS just do UI and platform APIs. That keeps the engine clean for things like Studio, and avoids dragging accounts and backend assumptions into it. And I wouldn't rush to make yet another repo, but I might make the Rust repo a workspace with multiple crates. The test I keep coming back to is, if iOS, Android, and web should behave the same way, default to Rust, if they won't or shouldn't, keep it in the platform app.
