# CSFeedbackKit

Drop-in feedback capture for iOS apps, driven by one JSON config.

A tester opens the composer and writes a note. The package gathers context (screen, project fields,
device, screenshot, logs) and POSTs a versioned payload to whatever URL the config names.
What happens after delivery (tickets, triage, agents) is the receiver's job.

> **Status:** in use in Shizen (Xcode builds). Config, fields, composer, delivery, signing, link
> uploads, the on-device queue, and the screenshot trigger all work. The tray (`session`) isn't built
> yet. See [`PLAN.md`](PLAN.md).

- iOS 16.4+, Swift 6, no dependencies
- UIKit first, with SwiftUI entry points
- Two products: `CSFeedbackKit` (core: config, fields, payload, delivery) and
  `CSFeedbackKitUI` (composer, screenshot trigger, queue screen, SwiftUI). Apps import `CSFeedbackKitUI`,
  which re-exports core.

---

## Quick start

The fastest path is the starter in [`Examples/Starter/`](Examples/Starter):

| File | What to do with it |
|---|---|
| `Feedback.json` | Copy into the app target. Edit tags, fields, and the destination. |
| `FeedbackSetup.swift` | Copy into the app target. Call `FeedbackSetup.start()` at launch and fill in the TODOs. |
| `FeedbackSecrets.plist.example` | Copy as `FeedbackSecrets.plist` into the app target, **add it to `.gitignore`**, and fill in the URL and secret. |

Then add the package (step 1), take a screenshot in the app, and you should see the prompt.
The steps below explain each piece.

### 1. Add the package

Xcode → Add Package Dependencies → `https://github.com/coltonswapp/CSFeedbackKit` (private; your GitHub
account must be signed in under Xcode → Settings → Accounts) → Up to Next Major from `0.1.0` → add
**CSFeedbackKitUI** to the app target. For working on the package alongside an app, add it by local path instead.

### 2. Add `Feedback.json` to the app target

```jsonc
{
  "$schema": "https://…/csfeedbackkit.config.v1.schema.json",   // optional; or a relative path to Schemas/
  "version": 1,
  "enabledIn": ["xcode", "testflight"],
  "tester": { "source": "field", "field": "userEmail" },
  "fields": [
    { "key": "userEmail", "label": "Account", "sources": ["session"], "sensitive": true },
    { "key": "grillId",   "label": "Grill",   "sources": ["screen", "session"] }
  ],
  "tags": [{ "id": "bug", "label": "Bug" }, { "id": "idea", "label": "Idea" }],
  "destinations": [
    { "id": "intake", "url": "${FEEDBACK_URL}",
      "signing": { "scheme": "standard-webhooks", "secret": "${FEEDBACK_SECRET}" } }
  ],
  "attachments": { "screenshot": { "defaultOn": true }, "device": {}, "logs": { "lastMinutes": 10 } },
  "triggers": [{ "type": "screenshot", "prompt": "Send feedback about this screen?" }]
}
```

Everything except `version` and `destinations` is optional. Leave out what a project doesn't need:
no `attachments.screenshot` means no screenshots, no `triggers` means the composer only opens from code.
Full examples: [`Examples/configs/grill.json`](Examples/configs/grill.json), [`Examples/configs/shizen.json`](Examples/configs/shizen.json).

### 3. Supply `${NAME}` values

`${NAME}` works in destination `url`, `headers`, and `signing.secret`, and in `storage` `url` and `headers`.
It resolves in this order: `variables:` passed to `Feedback.start` (use this for secrets kept out of the
repo, e.g. a gitignored plist), then scheme environment variables (DEBUG only), then Info.plist.
For per-configuration values, map Info.plist keys to build settings:

```
Info.plist:   FEEDBACK_URL = $(FEEDBACK_URL)
Beta.xcconfig: FEEDBACK_URL = https:/$()/intake.example.com/feedback
```

xcconfig treats `//` as a comment, hence `https:/$()/`. An unset or empty value is a config error.
Secrets never go in `Feedback.json`.

### 4. Start at launch

```swift
import CSFeedbackKitUI

Feedback.start(
    config: .bundled("Feedback"),
    variables: ["FEEDBACK_SECRET": Secrets.feedbackSecret],                          // optional, for ${NAME}
    auth:   ["staff": { ["Authorization": "Bearer \(try await Auth.token())"] }],   // names used by destinations[].auth
    checks: ["staffAccess": { Staff.isStaff }]                                        // name used by enabledWhen
)
Feedback.installTriggers()                                       // lets "triggers" open the composer
Feedback.appearance = FeedbackAppearance(sendButton: .yellow)    // optional, see Appearance
```

`installTriggers()` lives in the UI module, which is why it's a separate call. Without it, a configured
screenshot trigger does nothing and logs a `fault` the first time a screenshot is taken.

### 5. Supply field values

```swift
// App-wide (session source). Read at capture time.
Feedback.session.provide("userEmail") { AuthStore.shared.currentUser?.email }

// UIKit screen (screen source)
extension GrillDetailViewController: FeedbackContextProvider {
    func feedbackValues() -> FeedbackValues { ["grillId": .string(grill.id)] }
}

// SwiftUI screen
GrillDetailView(grill: grill).feedbackContext(["grillId": .string(grill.id)])
```

### 6. Open the composer

- **Screenshot:** with a `screenshot` trigger and `installTriggers()`, taking a screenshot offers the composer.
- **From code:**
  ```swift
  Feedback.present(from: self)        // UIKit; returns false when inactive
  FeedbackButton()                     // SwiftUI; hidden when inactive
  ```
- **The queue** (notes waiting, failed, or sent), usually from a debug menu:
  ```swift
  navigationController?.pushViewController(Feedback.makeQueueViewController(), animated: true)
  ```

### 7. Build the receiver

Any HTTPS endpoint that accepts the POST, checks the signature, returns **2xx** once the note is saved,
and dedupes on the payload `id`. See [Delivery](#delivery) for what each status code does.
To try it locally: `node Examples/receiver.mjs` and point a destination at `http://<mac-ip>:8787/`.
Payloads and decoded attachments land in `./received/<id>/`.

---

## Concepts

### Config vs code

The file says **what** happens. Code supplies only what a file can't hold, registered **by name**:

| In `Feedback.json` | In code |
|---|---|
| destinations, tags, fields (declarations), attachments, triggers, copy | auth handlers (`destinations[].auth`) |
| environments, static field values | checks (`enabledWhen`) |
| per-destination `format`, `attachments`, `when` routing | format handlers (`destinations[].format`) |
| | field values (session + screen providers), appearance |

Secrets never go in the file. A name in the file with nothing registered for it is a config error.

### Environments and gating

`xcode` (DEBUG or simulator), `testflight`, `appstore`. Detection uses `AppTransaction` and **fails closed**:
if it can't tell, the build counts as `appstore`. That's why a TestFlight build promoted to the App Store stays inert.

`Feedback.isActive` = config loaded **and** environment in `enabledIn` **and** the `enabledWhen` check
(if any) passes. Destinations, attachments, and triggers can narrow further with their own `environments`.

### Custom fields

Declared in `fields`, sent under `custom` in the payload.

- **Sources:** `value` (static) · `session` (`Feedback.session.provide`) · `screen` (`FeedbackContextProvider`, `.feedbackContext`).
- **Precedence:** screen (nearest first) → session → static. A field only accepts sources listed in its `sources`.
- **Only declared keys are sent.** Undeclared keys, wrong types, and disallowed sources are dropped with a
  `fault` in the `CSFeedbackKit` log. They never crash and never block capture.
- **Types:** `string`, `number`, `bool`, `stringArray`. Flat on purpose.
- **Frozen at capture.** A logout or screen change after opening the composer doesn't change the note.
- `required`: the composer asks the tester if nothing supplied it. `sensitive`: masked in the composer, sent in full.
  `visible: false`: hidden from the composer, still sent.

Screen provider order: the visible child view controllers, then the screen, then its parents and presenters,
then SwiftUI `.feedbackContext` values (the most recently shown first).

### Layered configs

```swift
Feedback.start(config: .merged(["Feedback", "Feedback.Checkout"]))
```

Later files override earlier ones. Objects merge by key. `fields` merge by `key`; `tags` and
`destinations` by `id`; `triggers` by `type`. Other arrays are replaced.

### Validation

Runs at `start`. Catches unknown or typo'd keys (with suggestions), duplicate ids, unregistered
`auth` and `enabledWhen` names, undeclared `tester.field`, static values of the wrong type, bad URLs,
unresolved `${NAME}`, and environment lists that never overlap `enabledIn`.
**DEBUG builds stop with every problem listed. Release builds log them and stay inactive.**

### Screenshot trigger

```jsonc
"triggers": [{ "type": "screenshot", "prompt": "Send feedback about this screen?", "environments": ["testflight"] }]
```

- Needs `Feedback.installTriggers()` after `start`.
- Fires only while `Feedback.isActive` is true and the build is in the trigger's `environments` (all of `enabledIn` if absent).
- With `prompt`, an alert asks first (`copy.promptAction` / `copy.promptCancel`, default "Write a note" / "Not now").
  Without it, the composer opens directly.
- The system screenshot isn't used. The composer snapshots the app after the alert closes, with the
  screenshot toggle forced on.
- Skipped while a composer or an alert is already showing. To skip it elsewhere (e.g. while the app's own
  report sheet is open), set `Feedback.shouldOfferScreenshotPrompt = { screen in !(screen is MyReportSheet) }`.
- An app that already handles screenshots itself should leave `triggers` out and call `Feedback.present(from:)`.

### Tray (`session`)

Accepted in the config but **not built yet**. `"session": { "enabled": true }` currently has no effect.

---

## Delivery

`Feedback.save` builds the payload and writes it to the outbox. After that the note can't be lost.
`Feedback.deliver` then tries every destination once. `Feedback.submit` does both. The composer
dismisses after `save` and shows the delivery toast when `deliver` finishes, so testers never wait
on the network.

| Response | Result |
|---|---|
| 2xx | delivered; an `id` in a JSON response is kept |
| 401, 403, 408, 425, 429, 5xx, network error, auth handler error | retried: 5s → 10s → … → 10 min with jitter, honoring `Retry-After`, up to `maxAttempts` |
| other 4xx | failed for good |

- **Outbox and queue:** every note is saved to disk before anything is sent (Application Support,
  excluded from backup). Automatic retries run on launch, on foreground, when the network comes back,
  and when the next retry is due. When a destination gives up, the note is **kept as failed**, not
  deleted, so it can be resent by hand. Failed and waiting notes are kept 7 days. Sent notes are kept
  3 days, in case a receiver accepted one but lost it downstream. At most 100 notes are kept, and sent
  ones are dropped first.
- **Queue screen:** `Feedback.makeQueueViewController()` (push it from a debug menu) or
  `Feedback.presentQueue(from:)`. It lists Failed, Waiting, and Sent notes with a status for each
  destination, and offers Resend now, Resend to every destination, Copy note, Copy JSON, and Delete.
  The same operations are available in code: `Feedback.queue()`, `Feedback.resend(_:includingDelivered:)`,
  `Feedback.discard(_:)`.
- **Size budget** (`maxBodyBytes`, default 4 MB): shrink the screenshot to 800, 600, then 400 px, then drop
  logs, then drop the screenshot. The note always goes.
- **Request headers:** config `headers`, then the auth handler's headers (they win), then
  `Content-Type`, `Idempotency-Key: <payload id>`, `Accept: application/json`, and `User-Agent`.
  The auth handler runs before every attempt.
- **Composer outcome:** the sheet closes once the note is saved. Delivered shows `copy.sentToast`.
  Still retrying shows `copy.queuedToast`. Failed shows the reason and says the note is in the queue.
- No background `URLSession`: if the app is suspended mid-send, the note is retried later.

### Choosing what each destination gets

Each destination decides its own body, attachments, and which notes it receives:

```jsonc
"destinations": [
  { "id": "studio", "url": "${CMS_URL}/notes", "auth": "staff", "format": "shizenNote" },
  { "id": "bugs",   "url": "${BUGS_URL}", "format": "csfeedbackkit", "attachments": "none",
    "when": { "tags": ["bug", "ux"] } },
  { "id": "hana",   "url": "${HANA_URL}", "when": { "field": "agent", "is": "hana" } }
]
```

- **`format`**: `csfeedbackkit` (default, the v1 payload), `openbot` (OpenBot's `{type, occurredAt, data}`
  envelope), or a name you register in code. That lets you match an existing endpoint without changing the server:
  ```swift
  Feedback.start(config: .bundled("Feedback"), formats: [
      "shizenNote": { payload in ShizenNote(payload) }   // any Encodable; becomes the JSON body
  ])
  ```
  Format handlers run before every attempt and off the main actor, so keep them pure.
- **`attachments`**: `inline` (default, base64 in the body), `link` (uploaded, URL in the body; see below), or `none`.
- **`when`**: `tags` means any of the listed tags is selected. `field` means the declared field has a value, and with `is`
  it must equal that value (a list field must contain it). Every condition given must hold. A note goes to every
  destination it matches. If it matches none, `save` throws `.noDestinations`.

### Attachments as links (storage)

Bots and webhooks often can't use a base64 image. They need a URL to fetch. Give the config a
`storage` section and set `"attachments": "link"` on those destinations:

```jsonc
"storage": { "type": "presigned", "url": "${UPLOAD_SIGNER_URL}", "auth": "staff" },
"destinations": [
  { "id": "bot", "url": "${BOT_URL}", "format": "openbot", "attachments": "link" }
]
```

- Each attachment is uploaded **once per note** and then reused by every `link` destination and retry.
  It's re-uploaded only when the link is within an hour of expiring. A failed upload retries like a failed send.
- The payload attachment then has `url` (and `expires_at`) instead of `data`.
- **`presigned`** works with any bucket (S3, R2, GCS…) through a small signer on your server, so bucket
  credentials never touch the device:
  1. `POST <url>` with `{ "id", "filename", "content_type", "size" }` and the config's headers and auth
  2. The signer answers `{ "upload_url", "download_url", "headers"?, "expires_at"? }`
  3. The app `PUT`s the bytes to `upload_url` (with `Content-Type` and any returned `headers`)
  4. `download_url` goes in the payload. Use the note `id` in the object key so retries overwrite.
- **Anything else**: register an uploader and name it as the type.
  ```swift
  Feedback.start(config: …, uploaders: ["firebase": { upload in
      FeedbackUploadResult(url: try await MyStorage.put(upload.data, name: "\(upload.noteId)/\(upload.filename)"))
  }])
  ```
- Projects without screenshots skip all of this. `storage` is only needed (and only checked) when a
  destination uses `link`.

### Signed receivers

A destination can sign each request. The secret always comes from `${NAME}` (pass it with `variables:`):

```jsonc
{ "id": "openbot", "url": "${BOT_URL}", "format": "openbot",
  "signing": { "scheme": "openbot", "secret": "${BOT_SECRET}" }, "maxBodyBytes": 65536 }
```

| `scheme` | Body | Headers |
|---|---|---|
| `standard-webhooks` | the payload | `webhook-id` (= payload `id`), `webhook-timestamp`, `webhook-signature: v1,<base64 HMAC-SHA256>` over `id.timestamp.body`, keyed with the base64 bytes after `whsec_`. For Svix, Clerk, Resend, and newer OpenBot hosts. |
| `openbot` | use with `"format": "openbot"`: `{"type", "occurredAt", "data": <payload>}` | `X-OpenBot-Timestamp`, `X-OpenBot-Delivery-Id` (= payload `id`), `X-OpenBot-Signature: sha256=<hex>` over `timestamp.id.body`, keyed with the whole secret. JSON only, and OpenBot caps bodies at 64 KiB. |

Each attempt is re-signed with a fresh timestamp. The id and body stay the same, so receivers dedupe retries.
`eventType` (default `feedback.submitted`) becomes the payload's top-level `type`.

## Payload (`csfeedbackkit/v1`)

Schema: [`Schemas/csfeedbackkit.payload.v1.schema.json`](Schemas/csfeedbackkit.payload.v1.schema.json).

```jsonc
{
  "schema": "csfeedbackkit/v1",
  "id": "fb_3f1c…",                       // idempotency key, stable across retries
  "session_id": "ses_…",                  // tray submissions only (not built yet)
  "created_at": "2026-11-16T18:04:00.123Z",
  "note": "Temp graph stutters when switching probes",
  "tags": [{ "id": "bug", "label": "Bug", "metadata": { "kind": "bug" } }],
  "source": { "screen": "GrillDetailViewController", "title": "Backyard Grill" },
  "custom": { "userEmail": "pat@example.com", "grillId": "GR-88213" },
  "tester": { "identity": "pat@example.com" },
  "app": { "bundle_id": "com.example.grill", "version": "4.2.0", "build": "812", "environment": "testflight" },
  "device": { "model": "iPhone17,1", "os": "iOS 26.1", "locale": "en_US", "time_zone": "America/Denver" },
  "attachments": [
    { "kind": "screenshot", "content_type": "image/jpeg", "filename": "screenshot.jpg", "data": "<base64>" },
    { "kind": "logs", "content_type": "text/plain; charset=utf-8", "filename": "logs.txt", "data": "<base64>" }
  ]
}
```

With `"encoding": "multipart"`, this JSON is the `payload` part without `data`, and each attachment is
a file part named by its `filename`.

**Notes for receivers:**
- Dedupe on `id` or the `Idempotency-Key` header, because retries resend the same `id`.
- Respond 2xx quickly. Return 4xx only for bodies you will never accept, because 4xx means
  the outbox stops trying.

## Composer and appearance

The composer is a sheet with: a collapsible Context section (screen, visible fields with sensitive ones
masked, build), a Details section (only for missing required fields or the tester prompt), the note, tag
chips, `#screenshot` and `#logs` toggles, **Copy for agent**, and Send.

- **Screenshot:** the whole window, taken when the sheet opens (not when Send is tapped). Secure text
  fields are blacked out, and so is any view with `view.isFeedbackRedacted = true`.
- **Appearance hooks:**
  ```swift
  Feedback.appearance = FeedbackAppearance(
      pageBackground: .systemGroupedBackground,
      sendButton: .yellow,                       // .blue, .yellow, or custom ButtonColors
      selectedTagTint: .systemBlue,
      configureSheet: { sheet in /* detents, backgrounds */ },
      showToast: { presenter, toast in /* the app's own toast */ }
  )
  ```
  Without `showToast`, a small built-in toast is used.

## Troubleshooting

| Symptom | Check |
|---|---|
| Screenshot does nothing | `Feedback.installTriggers()` called? `triggers` present, `Feedback.isActive`, trigger `environments`, `shouldOfferScreenshotPrompt` |
| `present` returns `false` | `Feedback.isActive`: wrong environment, `enabledWhen` failed, invalid config, or a composer is already open |
| Field missing from `custom` | Console, subsystem `CSFeedbackKit`, category `fields`: undeclared key, wrong type, or source not allowed |
| Notes not arriving | Category `delivery` (per-attempt outcome); `await Feedback.pendingCount()` |
| No logs attached | Only `os_log`/`Logger` output is collected (not `print`). Default subsystem is the bundle id |
| App Store build shows feedback | `enabledIn` includes `appstore`, or detection returned `testflight` |

---

## Working on this package (agents and contributors)

Read [`PLAN.md`](PLAN.md) for phase status and what's next.

### Layout

```
Schemas/                      config + payload JSON Schemas (contracts)
Sources/CSFeedbackKit/
  Feedback.swift              public entry: start, isActive, session, capture, save/deliver/submit, queue, screenshot observer
  Config/                     FeedbackConfig types, ConfigSource, ConfigLoader (layers, ${NAME}), ConfigValidator
  Environment/                AppTransaction detection
  Values/                     SessionValues, FeedbackContextProvider, FieldResolver
  Attachments/                device/app info, tester identity, OSLogStore logs
  Payload/                    FeedbackPayload (wire format), FeedbackDraft/Capture/Error, PayloadBuilder
  Delivery/                   DestinationRequest (json/multipart, formats), RequestSigner, PayloadBudget,
                              AttachmentStorage (presigned), Outbox (actor), FeedbackQueueEntry
Sources/CSFeedbackKitUI/
  Feedback+Present.swift      Feedback.present(from:), Feedback.appearance
  Composer/                   FeedbackComposerViewController
  Triggers/                   Feedback.installTriggers(), screenshot prompt
  Queue/                      FeedbackQueueViewController (debug queue screen)
  Components/                 button, tag chip, tag flow (ported from Shizen)
  Capture/                    ViewSnapshotter (+ redaction), ViewControllerTree
  SwiftUI/                    .feedbackContext, FeedbackButton
Examples/                     Starter/ (copy-paste setup), sample configs, receiver.mjs
```

### Rules

- **Contracts change together.** A config key means updating `FeedbackConfig.swift`, the config schema, the
  `ConfigValidator` known-keys table, and semantic checks if needed. A payload field means updating
  `FeedbackPayload.swift` and the payload schema.
- **Payload compatibility:** additive optional fields are fine in v1. Renames, removals, or type
  changes mean `csfeedbackkit/v2`.
- **Defaults live in two places:** the Swift `init(from:)` and the schema `default`. Keep them equal.
- **No dependencies, no method swizzling, no private API** in the package. App-specific tricks go
  through `FeedbackAppearance` hooks.
- **Fail soft at runtime, loud at setup.** Config errors stop DEBUG builds. Bad provider values are
  logged and dropped. Capture never blocks on a provider.
- **Concurrency:** `Feedback` and the UI are `@MainActor`. `Outbox` is an actor. Model types are `Sendable`.
- **Core stays UI-free** except for the foreground and screenshot observers in `Feedback.swift` (behind
  `canImport(UIKit)`). Core can't present UI, so the screenshot observer calls `Feedback.triggerHandler`
  (`package` access), which `installTriggers()` sets.
- **No test target** by decision. Verify by building the package for iOS and running a sample app
  against `Examples/receiver.mjs`.
- **Keep the starter working.** A change to setup (a new required call, a renamed key) means updating
  `Examples/Starter/` and the Quick start together.
