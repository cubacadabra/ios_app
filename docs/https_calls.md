Yes — **the routes and API contract should move into Rust**, but I would not automatically make Rust itself perform every HTTPS request.

Given the architecture you have now, I think the cleanest boundary is:

> **Rust owns what request should happen. The host owns actually performing platform/network side effects.**

So instead of having this duplicated:

```swift
POST https://api.cubacadabra.com/profile/username
```

```kotlin
POST https://api.cubacadabra.com/profile/username
```

```js
fetch("https://api.cubacadabra.com/profile/username")
```

Rust should know:

```rust
ApiRequest {
    method: POST,
    path: "/profile/username",
    body: ...,
    auth: Required,
}
```

and the platform executes it.

## I would evolve your current effect architecture this way

You already have the idea of Rust emitting effects. Networking fits that extremely well.

For example:

```rust
pub enum AppEffect {
    Http(HttpRequest),
}
```

with:

```rust
pub struct HttpRequest {
    pub id: RequestId,
    pub method: Method,
    pub path: String,
    pub body: Option<Vec<u8>>,
    pub auth: AuthRequirement,
}
```

The username state machine does:

```rust
Action::SaveUsername
```

Rust responds by emitting:

```text
HTTP EFFECT

POST /v1/profile/username
authenticated = yes

{
    "username": "review"
}
```

Then:

```text
             Rust
               |
        "make this request"
               |
       ┌───────┼─────────┐
       │       │         │
     iOS    Android      Web
       │       │         │
 URLSession  OkHttp     fetch()
       │       │         │
       └───────┼─────────┘
               |
           backend
```

And the host sends the result back:

```rust
Action::HttpCompleted {
    request_id,
    status,
    body,
}
```

Rust parses it and updates state.

That gets you most of what you actually want.

---

## Why I prefer this over letting Rust perform HTTPS directly

You certainly *can* have Rust call the network itself.

For native:

```rust
reqwest
```

works well on iOS/Android/Desktop.

And `reqwest` also supports WASM using browser `fetch` underneath.

So technically you could have:

```text
SwiftUI
   ↓
Rust
   ↓
reqwest
   ↓
backend
```

everywhere.

That's attractive because you'd share almost everything.

But it also starts making your Rust core responsible for some annoying platform concerns:

* authentication/token storage
* token refresh
* browser cookies
* CORS
* TLS/platform networking
* app lifecycle
* network cancellation
* backgrounding
* keychain/keystore
* browser credentials
* platform-specific proxy/network behavior
* instrumentation

And most importantly, **authentication usually has a platform boundary anyway**.

Suppose iOS has a Supabase token stored securely in Keychain, Android has it in its secure storage, and web has the session managed through browser storage/cookies.

Rust shouldn't necessarily need to understand all of those storage mechanisms.

Instead Rust can say:

```rust
auth: AuthRequirement::User
```

and the platform network executor knows:

```text
"Oh, attach the current bearer token."
```

That's a nice boundary.

---

# What absolutely should move into Rust

This:

```text
/profile/username
/users/blocked
/cubes
/cubes/{id}
/players/{id}/block
/players/{id}/report
```

should not exist independently in three client implementations.

I'd probably make a crate such as:

```text
crates/
    api/
    app/
    client/
    engine/
```

where `api` contains things like:

```rust
pub struct UpdateUsernameRequest {
    pub username: String,
}

pub struct UpdateUsernameResponse {
    pub username: String,
}

pub fn update_username(username: String) -> ApiRequest {
    ApiRequest::post("/v1/profile/username")
        .authenticated()
        .json(UpdateUsernameRequest { username })
}
```

Similarly:

```rust
pub fn blocked_players() -> ApiRequest
pub fn block_player(id: PlayerId) -> ApiRequest
pub fn unblock_player(id: PlayerId) -> ApiRequest
pub fn report_player(id: PlayerId, reason: ReportReason) -> ApiRequest
pub fn cubes() -> ApiRequest
pub fn cube(id: CubeId) -> ApiRequest
```

Now if your backend changes:

```text
/users/blocked
```

to:

```text
/v2/safety/blocked-users
```

you change it **once**.

That's a meaningful win.

---

# Don't hard-code the hostname either

I'd also stop embedding:

```text
https://api.cubacadabra.com
```

throughout application code.

Rust should probably receive configuration at startup:

```rust
AppConfig {
    api_base_url: "https://api.cubacadabra.com",
}
```

Then development can use:

```text
http://localhost:8787
```

staging:

```text
https://staging-api.cubacadabra.com
```

production:

```text
https://api.cubacadabra.com
```

The platform supplies the environment; Rust owns the paths.

So:

```text
                 platform config
                       |
              api.cubacadabra.com
                       |
                       v
                shared Rust API
                       |
             /v1/profile/username
             /v1/cubes
             /v1/safety/blocked
```

---

# Authentication is where I'd draw the subtle line

I would **not** pass the bearer token into every Rust action like:

```rust
save_username(username, bearer_token)
```

That's ugly and spreads credentials through your semantic application API.

Instead Rust should just declare:

```rust
AuthRequirement::Required
```

The host-side executor does:

```swift
request.setValue(
    "Bearer \(currentToken)",
    forHTTPHeaderField: "Authorization"
)
```

or equivalent.

If token refresh happens, that's also probably handled below Rust's semantic app layer.

Rust doesn't care whether the token came from:

```text
Supabase
Sign in with Apple
Google
session cookie
some future auth provider
```

It merely knows:

> this operation requires an authenticated Cubacadabra user.

That's a much cleaner abstraction.

---

# You can share response parsing too

This is another big one.

Don't make Swift decode:

```swift
struct BlockedPlayerResponse: Codable
```

while Kotlin has:

```kotlin
data class BlockedPlayerResponse(...)
```

and JS has its own assumptions.

Rust should own the wire schema:

```rust
#[derive(Deserialize)]
pub struct BlockedPlayersResponse {
    pub players: Vec<BlockedPlayer>,
}
```

Then:

```text
JSON from server
       ↓
      Rust
       ↓
validated typed domain state
       ↓
Swift / Kotlin / JS snapshots
```

That prevents a surprisingly common class of cross-platform bugs.

If the backend changes from:

```json
{
  "blocked_users": [...]
}
```

to:

```json
{
  "players": [...]
}
```

you fix the API decoder once.

---

# This is one place where Rust sharing has a very strong argument

I'd actually rank backend API code as **more worth sharing than UI state like username validation**.

Because duplicated API clients inevitably drift.

You get:

```text
iOS:
POST /player/block

Android:
POST /players/block

Web:
POST /v2/players/block
```

or subtly different handling of:

```text
401
403
404
409
429
500
```

Or one client forgets a new field.

Centralizing this is valuable.

---

## So I'd end up with this

```text
                    cubacadabra-app
                    Rust state machine
                           |
                           v
                    cubacadabra-api
                routes / request types /
                response types / errors
                           |
                     HTTP effect
                           |
        ┌──────────────────┼──────────────────┐
        │                  │                  │
      iOS                Android             Web
   URLSession             HTTP              fetch
        │                  │                  │
    auth token          auth token        cookie/token
        │                  │                  │
        └──────────────────┼──────────────────┘
                           |
                        backend
```

And eventually you might discover that the three transport implementations are so thin that using `reqwest` inside Rust is easier. At that point you can move the bottom layer into Rust too.

But I **wouldn't start there**.

Your current action → effect → result architecture is almost tailor-made for:

> Rust constructs authenticated semantic API operations; host executes them.

That gives you the important reuse without forcing Rust to become iOS's Keychain manager, Android's credential manager, and the browser's session manager.

And yes: **I'd consider the current situation where endpoint strings and JSON contracts are independently hard-coded in Swift, Kotlin, and JS technical debt worth eliminating as part of this migration.**

