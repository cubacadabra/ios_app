Yes. There absolutely is a school of thought around **Rust-first / Kotlin-minimal Android apps**, especially for apps that are really cross-platform engines, editors, games, media tools, crypto clients, or other systems-heavy software.

The key distinction is that “100% Rust” can mean two different things. One is **all business logic, rendering, networking, storage, simulation, etc. in Rust, with a tiny Android shell**. That is quite practical. The other is **literally zero Kotlin/Java anywhere, including Android lifecycle and platform APIs**. That is possible in narrower cases, but it tends to fight the Android platform.

For your Cubacadabra-style architecture, I think Rust-first makes a lot of sense. You already have a shared Rust engine and native clients. Making Android mostly a platform adapter instead of a second implementation of your application logic is exactly the kind of case where Rust pays off. The Android layer can be reduced to things like `Activity` startup, permissions, billing, notifications, intents, file pickers, lifecycle callbacks, and handing a surface/window into Rust. Everything else can stay in Rust.

The common philosophies look roughly like this:

* **Rust core + thin Kotlin shell** — probably the most sensible architecture. Kotlin may only be a few hundred or few thousand lines.
* **NativeActivity / GameActivity + Rust** — common for games and graphics apps. Rust owns rendering and the main loop, Android mainly supplies the window/input/lifecycle.
* **Rust UI too** — using something like winit/wgpu/egui, Slint, Dioxus, or a custom renderer. This gets you much closer to a genuinely Rust application running on Android.
* **No Kotlin at all** — JNI/NDK-only approaches exist, but Android APIs that are fundamentally Java/Kotlin APIs become awkward. You end up writing JNI bindings yourself or depending on crates that do it.

The ironic part is that avoiding Kotlin completely often makes the codebase **less pleasant**, not more pleasant. You replace:

```kotlin
billingClient.launchBillingFlow(...)
```

with Rust → JNI → Java object construction → method signatures → exception handling → lifecycle plumbing. Even if you dislike Kotlin as a language, 30 lines of boring Kotlin glue can be much cleaner than 200 lines of JNI machinery.

So I wouldn't frame the philosophy as “Kotlin is bad, therefore Rust everywhere.” I'd frame it as:

> **Rust owns the product. Kotlin owns Android-specific bureaucracy.**

That gives you most of the advantages you probably want: one implementation of networking, protocol, simulation, content loading, state management, rendering, game logic, WebSockets, persistence formats, etc.; much less divergence between iOS/Android/desktop; better compiler-enforced correctness; and Android stops becoming its own software project.

For a conventional Android productivity app made mostly of lists, forms, accessibility-heavy controls, text fields, navigation, and native widgets, going all-Rust is usually a bad trade. Jetpack Compose is deeply integrated with Android and gives you a huge amount for free. But for a **game engine / studio / custom-rendered application**, the argument flips heavily toward Rust.

And this is not some fringe idea. Large cross-platform software has long followed variants of the same pattern: a native/platform-specific shell around a C/C++/Rust core. Rust is basically becoming a modern version of that architecture, with much nicer safety properties.

For **your particular project**, I'd probably aim for something like:

```text
android/
    MainActivity.kt       # tiny
    Billing.kt            # Android-only
    Notifications.kt      # Android-only
    Permissions.kt        # Android-only

rust/
    engine/
    client/
    networking/
    rendering/
    world/
    scripting/
    persistence/
```

and aggressively push anything that **doesn't intrinsically require an Android SDK object** out of Kotlin.

If you eventually wind up with something like **95–99% Rust and 1–5% Kotlin**, I would consider that a better endpoint than making “zero Kotlin” a purity goal.


would any of the normal (not game play) parts of the android app in rust like menus and set username features etc get re-used in ios? Or android rust for those things would be very specific to android


Yes — a lot of the **non-gameplay logic** can be reused between Android and iOS if you design it that way. But the **actual native UI widgets** usually should not be.

The useful split is:

* **Rust can own the behavior/state**
* **Kotlin/Swift can own the native presentation**

For example, “set username” has several layers. The reusable Rust part can own username validation, normalization, availability checks, API calls, loading/error state, saving to local storage, analytics events, and deciding what happens after success. Android then has a Kotlin/Compose text field and button; iOS has a SwiftUI `TextField` and button. Both call the same Rust code.

Something like:

```text
Rust shared core
  ProfileState
  validate_username()
  check_username_available()
  save_username()
  logout()
  load_settings()
  update_parental_controls()
  navigation/domain state

Android
  Compose screen
  TextField
  Button
  Android navigation shell

iOS
  SwiftUI screen
  TextField
  Button
  NavigationStack
```

Menus are similar. If you mean the **contents and logic of the menu**—which items exist, whether “Log Out” is enabled, what settings are available, what happens when something is selected—that can absolutely be shared in Rust. If you mean the literal Android `DropdownMenu`, toolbar, navigation drawer, switch, text field, etc., that code is Android-specific.

There is another path: you can render the whole UI yourself in Rust using a cross-platform Rust UI framework or your own renderer. Then the same Rust menu and username screen could literally run on Android, iOS, macOS, Windows, and Linux. But you pay for that with weaker native feel, accessibility work, keyboard/text-input complexity, screen-reader integration, platform conventions, and more maintenance.

For Cubacadabra, I'd lean toward:

```text
                 shared Rust
                     |
       +-------------+-------------+
       |             |             |
   game engine   app/domain     networking
                 logic/state
       |             |             |
   --------      ---------      ---------
   renderer      profile       auth
   worlds        settings      API
   avatars       account       websocket
   scripting     purchases*
                 etc.

                     |
          platform presentation
            /              \
       SwiftUI            Compose
        iOS               Android
```

The important point is that you don't have to choose between “all native” and “all Rust.” You can make **most of the intellectually important application code Rust**, while SwiftUI and Compose become fairly dumb views over shared state.

That is probably the sweet spot for you. It would mean an Android username feature and an iOS username feature might share **80–95% of their logic**, while still having completely separate 20–50 lines of UI code for the actual screen.

And that is materially different from writing the whole feature twice. The duplicated part is mostly:

```swift
TextField(...)
Button(...)
```

versus:

```kotlin
TextField(...)
Button(...)
```

rather than duplicating validation, state machines, HTTP calls, persistence, error handling, and business rules.



where do you draw the line then with web and wasm? In theory then the web app could use all the same rust for web's menus as well?


Yes — and this is exactly where the architecture gets interesting.

With web + WASM, you can push the shared Rust boundary even further, because the browser can run a lot of the same Rust directly. But I’d still separate **UI model** from **UI rendering**.

A good line is:

* Rust owns app state, domain logic, validation, networking rules, menu models, settings models, routing decisions, permissions logic where portable, and game/client state.
* Each platform owns the final presentation layer: SwiftUI on iOS, Compose on Android, DOM/React/whatever on web.

So the same Rust could expose something like:

```rust
struct SettingsMenu {
    items: Vec<MenuItem>,
}

enum MenuItem {
    SetUsername,
    Audio,
    Privacy,
    SignOut,
}
```

and the same Rust decides:

```rust
fn settings_menu(state: &AppState) -> SettingsMenu
```

Then:

```text
iOS     -> SwiftUI renders it
Android -> Compose renders it
Web     -> HTML/DOM renders it
```

That gives you one source of truth for things like “show this menu item only when logged in” or “username must be 3–20 chars,” without trying to reuse the literal UI code.

For web, you have three choices.

The first, and probably best for Cubacadabra, is **Rust/WASM core + normal web UI**. Rust compiles to WASM, JavaScript calls it, and the DOM handles menus/forms. That gives you maximum platform quality with high logic reuse.

The second is **Rust UI framework across everything**. Something like Dioxus, Leptos, egui, Slint, etc. Then your actual menu implementation may be shared across web, desktop, maybe mobile too. This is tempting, but now you've effectively chosen a cross-platform UI toolkit and are accepting its compromises.

The third is **custom-rendered UI inside your engine**. Then your settings screen, username dialog, menus, etc. are literally engine UI and could be identical everywhere:

```text
Rust
  UI layout
  widgets
  input
  text rendering
  navigation
  state

        ↓

Metal       Vulkan       WebGPU
iOS         Android      Browser
```

For a game, this can make sense for **in-game UI**.

I would not necessarily use it for account/login/settings screens outside gameplay.

I'd draw Cubacadabra's boundary something like this:

```text
                         SHARED RUST
┌─────────────────────────────────────────────────┐
│ engine                                          │
│ networking                                      │
│ protocol                                        │
│ game state                                      │
│ auth/session state                              │
│ profile state                                   │
│ username validation                             │
│ settings state                                  │
│ menu definitions                                │
│ entitlement state                               │
│ navigation/domain decisions                     │
└─────────────────────────────────────────────────┘
               │           │           │
               ▼           ▼           ▼
            iOS UI      Android UI     Web UI
           SwiftUI       Compose        DOM
```

Then inside the actual game:

```text
                         SHARED RUST
┌─────────────────────────────────────────────────┐
│ rendering                                       │
│ HUD                                             │
│ inventory                                       │
│ chat overlay                                    │
│ avatar picker                                   │
│ game menus                                      │
│ world UI                                        │
└─────────────────────────────────────────────────┘
               │           │           │
              Metal       Vulkan      WebGPU
```

That's the distinction I'd use:

**Product/app chrome:** native/web UI.

**Game/world UI:** shared Rust rendering.

And yes, this can lead to a very high reuse percentage. You could plausibly have iOS, Android, desktop, and web all sharing the same:

* profile model
* settings model
* auth state
* networking
* websocket client
* content loading
* entitlement logic
* username validation
* game state
* scripting
* rendering abstraction

while each platform only supplies a relatively thin UI/platform shell.

The trap is chasing “100% shared UI.” That's usually where cross-platform projects start feeling uncanny. Sharing **the model of the menu** is hugely valuable. Sharing **every pixel of the menu** usually isn't.



here are screen shots from current ios and current web apps for the same sections currently ios is all swiftUI and web is all html/css/js - help me understand how these two could share more via rust but still keep their native platform textfield and menus etc


Yes. Looking at these screenshots, you have a very good candidate for sharing substantially more through Rust **without making either app look cross-platform or generic**.

The cleanest mental model is:

> Rust owns what the screens *mean* and what they *do*.
> SwiftUI and HTML/CSS own how the screens *look and feel*.

Your current iOS and web UIs are already different enough visually that I would **not** try to share their actual layout code. The iPad app is very Apple-like: grouped cards, native navigation, native text fields, iOS spacing, back buttons, contextual menus. The web app is more desktop/dashboard-like: sidebar, dark theme, horizontal navigation, desktop forms. Trying to force those through one UI toolkit would probably make both worse.

But underneath those surfaces, there's a lot you can share.

For example, take your **Username** screen.

Today you probably have something conceptually like:

```text
iOS Swift
- current username state
- validation rules
- API request
- loading state
- error handling
- update profile state
- save button behavior

Web JS
- current username state
- validation rules
- fetch()
- loading state
- error handling
- update profile state
- save button behavior
```

That's duplication.

Instead, Rust could own:

```rust
pub struct UsernameModel {
    pub current: String,
    pub draft: String,
    pub status: UsernameStatus,
}

pub enum UsernameStatus {
    Idle,
    Invalid(String),
    Saving,
    Saved,
    Failed(String),
}

impl UsernameModel {
    pub fn set_draft(&mut self, value: String);
    pub fn can_save(&self) -> bool;
    pub async fn save(&mut self) -> Result<(), ProfileError>;
}
```

Then iOS remains completely native:

```swift
TextField("Username", text: $username)

Button("Save Username") {
    model.saveUsername(username)
}
```

And web remains completely native:

```html
<input id="username">
<button>Save</button>
```

with JS/WASM:

```js
model.setDraft(input.value)
await model.save()
```

Same Rust feature. Two completely different front ends.

That pattern maps very well to nearly every screen you've shown.

For **Choose your morph**, Rust could own:

```rust
pub struct Morph {
    pub id: MorphId,
    pub name: String,
    pub asset: AssetId,
}

pub struct MorphPicker {
    pub options: Vec<Morph>,
    pub selected: MorphId,
}

impl MorphPicker {
    pub fn select(&mut self, id: MorphId);
    pub async fn save(&self) -> Result<(), ProfileError>;
}
```

The iOS side decides that options are three big rounded cards in a horizontal SwiftUI layout.

The web side decides that they are desktop cards inside your dark dashboard.

Rust doesn't care.

For **Your Cubes / Cubes / More**, Rust could own the whole data model:

```rust
pub struct CubeSummary {
    pub id: CubeId,
    pub slug: String,
    pub title: String,
    pub version: Version,
    pub subtitle: Option<String>,
    pub thumbnail: Option<AssetId>,
}

pub struct CubeLibrary {
    pub pinned: Vec<CubeSummary>,
    pub uploaded: Vec<CubeSummary>,
}
```

And:

```rust
pub async fn load_my_cubes() -> Result<CubeLibrary, Error>;
pub async fn load_uploaded_cubes() -> Result<Vec<CubeSummary>, Error>;
pub async fn enter_cube(id: CubeId) -> Result<LobbyTarget, Error>;
```

Then your iOS list can keep looking exactly like this:

```text
Adventure 101
adventure-101 · v0.4.1
>
```

while your web version keeps using the thumbnail-plus-title layout.

Same underlying Rust object.

Your **Players & Safety** screen is another excellent candidate. Rust can own almost everything important:

```rust
pub struct Player {
    pub id: PlayerId,
    pub display_name: String,
    pub presence: Presence,
}

pub struct SafetyState {
    pub nearby_players: Vec<Player>,
    pub blocked_players: Vec<Player>,
}

pub async fn block_player(id: PlayerId);
pub async fn unblock_player(id: PlayerId);
pub async fn report_player(id: PlayerId, reason: ReportReason);
```

The actual context menu:

```text
Report player
Block player
```

should remain native SwiftUI on iOS.

On the web it could be a dropdown menu.

On Android it could be a Compose popup menu.

But all three call:

```rust
safety.block_player(player_id)
```

That is the kind of sharing I'd chase.

The biggest architectural win, though, is to go one step above individual models and have Rust expose **screen/application state**.

Something like:

```rust
pub enum Route {
    Home,
    Username,
    MorphPicker,
    CubeLibrary,
    UploadedCubes,
    PlayersSafety,
    Privacy,
}
```

and:

```rust
pub struct AppState {
    pub profile: ProfileState,
    pub cubes: CubeState,
    pub safety: SafetyState,
    pub session: SessionState,
}
```

Then all platforms run basically the same application:

```text
                 Rust application core

      session
         |
      profile
         |
      cubes
         |
      safety
         |
      navigation
         |
      networking
         |
      persistence

       /             |              \
      /              |               \
 SwiftUI          Compose           Web DOM
   iOS             Android         JS/WASM
```

That's where you start getting serious leverage.

There's another useful distinction: **data models vs view models**.

I'd share both where possible.

A raw model might be:

```rust
struct User {
    username: String,
    morph: MorphId,
}
```

A reusable view model might expose exactly what UI needs:

```rust
struct ProfileScreen {
    username: String,
    username_help: String,
    morphs: Vec<MorphOption>,
    selected_morph: MorphId,
    save_enabled: bool,
}
```

This means Swift doesn't need to reconstruct business rules, and JavaScript doesn't either.

Both simply render what Rust gives them.

Your platform code becomes almost boring:

```swift
if screen.saveEnabled {
    Button("SAVE USERNAME") { ... }
}
```

and:

```js
saveButton.disabled = !screen.saveEnabled
```

That's a feature, not a problem.

Where I **would not** share is anything tied to how the OS works visually.

For these screenshots, I'd leave these platform-native:

* `TextField` / `<input>`
* buttons
* navigation bar
* back button
* sidebars
* scroll behavior
* sheets
* alerts
* context menus
* keyboard behavior
* focus handling
* accessibility representation
* responsive layout
* typography
* hover states
* system colors

For example, your iOS "More" page and your web "More" page have basically the same semantic contents:

```text
More
Browse uploaded cubes

Adventure 101
Survival 101
The Wild West
...
```

But they should **not** share rendering. The iPad version naturally looks like a native grouped list. The desktop web version naturally looks like a content catalog next to the persistent sidebar.

Rust can just say:

```rust
UploadedCubesScreen {
    title: "More",
    subtitle: "Browse uploaded cubes",
    cubes: [...]
}
```

Then each platform interprets that.

There's also a nice consequence for Android.

If you do this now, Android becomes much cheaper to build because you're no longer building:

```text
iOS implementation
web implementation
Android implementation
```

You're building:

```text
                shared feature implementation
                         Rust
                           |
          +----------------+----------------+
          |                |                |
      SwiftUI           Compose            DOM
```

Android only has to implement the visual shell.

That means a new feature like "rename username" might involve:

```text
Rust:
  + validation
  + API
  + state
  + errors
  + tests

iOS:
  + 40 lines SwiftUI

Android:
  + 50 lines Compose

Web:
  + 30 lines HTML/JS
```

instead of implementing the real feature three times.

One thing I would be careful about: don't have Rust emit a generic description of every widget like:

```rust
Screen {
    controls: [
        TextField { ... },
        Button { ... },
        Card { ... },
    ]
}
```

That's basically inventing your own cross-platform UI framework.

It sounds appealing, but you'll gradually end up recreating SwiftUI/Compose/HTML badly.

I'd instead share **semantic screen state**, not widget trees.

Good:

```rust
ProfileScreen {
    username,
    morphs,
    selected_morph,
    save_enabled
}
```

Not:

```rust
VerticalStack([
    Label(...),
    TextField(...),
    Button(...)
])
```

That distinction is probably the most important architectural rule here.

For Cubacadabra, I could see a Rust crate structure eventually looking something like:

```text
crates/
    engine/
    client/
    auth/
    profile/
    cubes/
    safety/
    app/
```

where `app` coordinates the non-game product experience.

Then platform repos/modules become:

```text
ios/
    HomeView.swift
    UsernameView.swift
    MorphView.swift
    CubesView.swift
    SafetyView.swift

android/
    HomeScreen.kt
    UsernameScreen.kt
    MorphScreen.kt
    CubesScreen.kt
    SafetyScreen.kt

web/
    home.js
    username.js
    morph.js
    cubes.js
    safety.js
```

But those files become mostly views and event forwarding rather than separate applications.

Given the screens you've shown, I think you could realistically move **a majority of the non-rendering app logic** into Rust while preserving 100% of the native feel you currently have.

And this actually fits your project unusually well because you're already committing to Rust as the common engine layer rather than introducing Rust solely to share some form validation.

