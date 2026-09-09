I looked through the Sep 9 commits in all four repos. My read is: **the direction is defensible and is already showing some payoff, but you are right at the point where a good senior engineer would challenge you to prove it rather than keep expanding it on faith.**

I would **keep going**, but I would not make “move everything possible into Rust” the goal.

The strongest evidence that this is working is actually iOS. The new `cubacadabra-app` crate explicitly defines the boundary as semantic product state outside gameplay while leaving SwiftUI, Compose, and the DOM native. That's exactly the architecture we were talking about. ([GitHub][1])

And then in iOS, commit `bbde24e` is a genuinely encouraging result: **106 lines added, 269 removed** across the integration. The username SwiftUI screen stopped owning its own runtime, networking/error machinery, and save workflow; it became a view over `model.profileUsername`, with calls like `saveProfileUsername()` and `changeProfileUsername()`. ([GitHub][2])

That is what success should look like.

### What you've actually built

The architecture now looks roughly like:

```text
                       cubacadabra-app (Rust)

                    actions → state → snapshots
                         ↓             ↑
                       effects/results

                ┌────────┼─────────┐
                │        │         │
              Swift     Kotlin      JS
                │        │         │
             SwiftUI    Compose     DOM
```

Rust does things like:

```text
UsernameChanged
SaveUsername
UsernameSaved
UsernameSaveFailed
```

and owns:

```text
draft
dirty
valid
canSave
saving
feedback
accepted username
session identity
```

while the platform still owns:

```text
SwiftUI TextField
Compose TextField
HTML <input>

navigation
focus
keyboard
menus
animation
accessibility presentation
```

The Rust crate even describes itself that way: `cubacadabra-app` owns semantic app state, while SwiftUI, Compose, and DOM stay native. ([GitHub][1])

That's a good boundary.

---

## The skeptical senior developer has a legitimate argument

If I were reviewing this PR cold, one thing would jump out immediately:

> “You built a Rust state machine, serialization protocol, C ABI, Swift adapter, JNI adapter, WASM adapter, effect system, and contract tests… to save a username?”

That's not an unfair criticism.

The first `cubacadabra-app` commit alone was **636 additions** and introduced actions, effects, snapshots, validation, profile state, tests, FFI planning, and documentation. ([GitHub][1])

Then you had significant integration work afterward. The latest Rust restructuring itself is another **607 additions / 514 deletions**, including simplifying a bunch of individual native C functions into a generic JSON `dispatch` interface. ([GitHub][3])

Android now needs a C JNI adapter plus a Kotlin `AppRuntime` that marshals JSON into Kotlin data classes. That's ~115 new lines in the latest adapter commit before counting the surrounding integration. ([GitHub][4])

And web is currently the least convincing result in terms of raw simplicity. The latest app-runtime integration is **301 additions / 86 deletions**. The old username validation and direct username `fetch()` disappeared—which is good—but it was replaced with runtime initialization, subscriptions, session checking, effect handling, WASM loading, and contract tests. ([GitHub][5])

So yes: **right now this is more infrastructure than duplicating 20 lines of username validation three times.**

If Cubacadabra consisted of ten forms like this and little else, I'd tell you to undo this.

But that's not the application you're building.

---

# Where I think the calculation changes

Username validation is almost the **worst possible feature to demonstrate the benefit** because the duplicated implementation is tiny.

These are much better examples:

```text
Blocked users
    loading
    refresh
    stale state
    unblock
    optimistic update
    request failure
    account/session changed during request
    pagination eventually
    reporting state

Cube catalog
    loading
    refresh
    versions
    availability
    ownership
    filtering
    downloading
    cached state
    errors
    launch eligibility

Account/profile
    age state
    username
    morph
    parental relationship
    capabilities
    entitlements
    auth/session changes

Purchasing
    entitlement normalization
    subscription status
    feature availability
    restore state
```

Now imagine maintaining those state machines independently in:

```text
Swift
Kotlin
JavaScript
```

That's where duplication starts hurting.

It's not primarily that typing the same code three times takes a long time. The expensive problem is that six months later:

```text
iOS handles case A
Android handles case A + B
web handles B differently
iOS fixed race C
web never got the fix
Android reports a different error
```

A shared Rust state machine prevents that kind of semantic drift.

And your current architecture has already hit real problems of this nature: the web implementation now has explicit session identity checks and page restoration handling, while the iOS implementation makes sure responses can't update the wrong account after a session change. Those are exactly the kinds of subtle lifecycle rules that are worth centralizing. ([GitHub][6])

---

# One thing I particularly like about what changed

Originally, the native Rust API started heading toward:

```text
cubacadabra_app_username_changed(...)
cubacadabra_app_save_username(...)
cubacadabra_app_username_saved(...)
cubacadabra_app_username_save_failed(...)
...
```

That would become awful.

Imagine adding 40 features and ending up with 150 C entry points.

The latest Rust commit backs away from that and moves toward:

```text
dispatch JSON
get snapshot JSON
poll effect JSON
```

The diff explicitly removes those dedicated username C functions and replaces them with generic `cubacadabra_app_dispatch_json(...)` and shared output handling. ([GitHub][3])

I think that's the right correction.

Your ABI can stay tiny forever:

```text
create
destroy
dispatch
snapshot
poll_effect
```

while Rust evolves internally.

That's much more sustainable.

---

# But there's one architectural smell I'd watch

You are currently putting the non-game `AppRuntime` into the **GameViewModel**.

For example, iOS now has:

```swift
extension GameViewModel {
    var profileUsername: AppRuntimeProfileSnapshot ...
    func changeProfileUsername(...)
    func saveProfileUsername(...)
}
```

and the SwiftUI account view observes the `GameViewModel`. ([GitHub][6])

Android similarly puts the Rust profile snapshot into `GameUiState`. ([GitHub][7])

That is okay as an intermediate step, but I'd eventually want:

```text
AppModel / AppViewModel
    account
    profile
    cubes
    safety
    entitlements

GameViewModel
    active world
    renderer
    player
    gameplay
```

Otherwise you've carefully avoided creating a Rust god-crate only to create a platform-side `GameViewModel` god-object.

Your Rust architecture already has the right separation:

```text
cubacadabra-engine
cubacadabra-client
cubacadabra-app
```

I'd eventually mirror that distinction in the hosts.

---

# I would also *not* Rust-ify trivial things

This is where I'd push back against the purity instinct.

Your iOS screen has:

```text
Privacy Policy
Terms of Use
Contact support
```

There is almost no value in having Rust emit:

```rust
MenuItem::PrivacyPolicy
MenuItem::TermsOfUse
MenuItem::ContactSupport
```

unless their availability has actual business rules.

Just write those three rows in SwiftUI, Compose, and HTML.

Likewise:

```text
"USERNAME"
"Choose a name other players can find you by."
"SAVE USERNAME"
```

doesn't necessarily need to come from Rust.

The valuable shared thing is:

```text
username = "review"
can_save = false
saving = true
validation_error = TooShort
```

Not:

```text
button text = "SAVE USERNAME"
corner radius = 18
```

That keeps this architecture from metastasizing.

---

# What would convince me this was a mistake?

I would run one very specific experiment now.

Don't spend months migrating everything.

Move **two more substantial features** through `cubacadabra-app`:

1. cube catalog / "More"
2. blocked users + unblock/report state

Then look at the result.

I'd expect adding a feature eventually to look like:

```text
Rust
    150–300 lines actual feature/state/tests

Swift
    30–80 lines presentation integration

Kotlin
    30–80 lines presentation integration

JS
    30–80 lines presentation integration
```

rather than:

```text
Rust
    250 lines

Swift bridge
    200 lines

JNI
    150 lines

Kotlin adapter
    200 lines

WASM adapter
    150 lines

JS runtime
    250 lines
```

If you're still getting the latter after the framework has stabilized, **stop**. Duplication would be cheaper.

That's the test.

---

# And yes, some excellent senior developers would choose duplication

There isn't one universally correct answer here.

A senior mobile engineer could reasonably say:

> Swift is excellent at this on iOS. Compose is excellent at it on Android. JavaScript is excellent at it on the web. Let each application implement its own app layer and only share the game engine.

That architecture has real advantages:

* fewer language boundaries
* easier debugging
* no serialization protocol
* better IDE support
* simpler builds
* easier hiring/onboarding
* platform code is completely idiomatic
* no FFI lifecycle bugs

I wouldn't call that engineer wrong.

For a company with:

```text
5 iOS engineers
5 Android engineers
5 web engineers
```

I might actually favor their argument more strongly. Each platform team can comfortably own its implementation.

For a small team maintaining **three clients plus a shared game engine**, the economics are different. One semantic implementation has a lot more appeal.

---

# My current scorecard

After actually looking at the commits rather than just reasoning abstractly:

| Area                               | My read                                    |
| ---------------------------------- | ------------------------------------------ |
| Rust `app` crate boundary          | **Very good**                              |
| Keeping native UI                  | **Definitely right**                       |
| Engine/client/app crate separation | **Good**                                   |
| Generic action/snapshot/effect ABI | **Good correction**                        |
| iOS result                         | **Already promising**                      |
| Android result                     | **Promising, but adapter cost is visible** |
| Web result                         | **Not yet clearly cheaper**                |
| Current amount of infrastructure   | **High**                                   |
| Risk of overengineering            | **Real, manageable**                       |
| Should you revert?                 | **No**                                     |
| Should you migrate everything now? | **Also no**                                |

The biggest thing that changed my confidence after reading the commits is that **the iOS code actually got materially simpler once the ownership was moved into the shared runtime**. That's exactly the payoff this architecture promised, rather than merely theoretical reuse. ([GitHub][2])

So I'd keep the direction change.

But I'd make the next two or three features a **trial period**. If cube catalog and safety become dramatically thinner on every host, you've probably found the architecture for Cubacadabra. If they instead produce hundreds of lines of FFI/WASM glue for every 50 lines of behavior you share, the skeptical “just duplicate it” senior developer wins.

Right now I'd put it about **70/30 in favor of continuing the Rust app-core approach**. The architecture itself is good; the remaining question is whether its amortized cost becomes low enough as you add features.

[1]: https://github.com/cubacadabra/rust/commit/1221dcd28f6526e086e7721a97c8f22dc735e5b0 "cubacadabra-app crate · cubacadabra/rust@1221dcd · GitHub"
[2]: https://github.com/cubacadabra/ios_app/commit/bbde24eb3edb07cb2f580dc2bd17e8ef15cc32d3 "more crate idea · cubacadabra/ios_app@bbde24e · GitHub"
[3]: https://github.com/cubacadabra/rust/commit/b4e0fd953889589e8f49f03a137ee2f654332a2e "more crate idea · cubacadabra/rust@b4e0fd9 · GitHub"
[4]: https://github.com/cubacadabra/android_app/commit/c52ca7e9c8d3d78f9eb281dce57bfbfbb7d8b042 "more crate idea · cubacadabra/android_app@c52ca7e · GitHub"
[5]: https://github.com/cubacadabra/web/commit/febc584fb0e8832a7831df7024be081f2bfbb00b "more crate idea · cubacadabra/web@febc584 · GitHub"
[6]: https://github.com/cubacadabra/ios_app/commit/577f46056211d754ddeb6bc1164c9de38b236093 "more crate idea · cubacadabra/ios_app@577f460 · GitHub"
[7]: https://github.com/cubacadabra/android_app/commit/5a5e348c2f0af8b80422c8f4d2bec02b5359370d "more crate idea · cubacadabra/android_app@5a5e348 · GitHub"

