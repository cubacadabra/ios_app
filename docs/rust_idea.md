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

