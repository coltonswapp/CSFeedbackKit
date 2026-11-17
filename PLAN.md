# CSFeedbackKit plan

Drop-in feedback capture for iOS apps. One JSON config drives it. It captures a note,
context, and attachments, and POSTs a versioned payload to whatever URL the config names.
What happens after delivery is the receiver's job.

## Decisions

- iOS 16.4+, Swift 6, no dependencies.
- UIKit first. A thin SwiftUI entry point for SwiftUI apps.
- Triggers: screenshot (per environment) + programmatic `Feedback.present(from:)`. No shake.
- Gating at runtime via `AppTransaction` environment (xcode / testflight / appstore), so
  a TestFlight build promoted to the App Store stays inert.
- Config declares fields. Code supplies values (session + screen providers). Only declared
  keys are sent, under `custom`. Values are captured at note time.
- Secrets and dynamic things are never in the file: named auth handlers and checks are
  registered in code; `${NAME}` resolves from Info.plist.
- No test target.

## Contracts (Phase 0, done)

- `Schemas/csfeedbackkit.config.v1.schema.json` ↔ `Sources/CSFeedbackKit/Config/FeedbackConfig.swift`
- `Schemas/csfeedbackkit.payload.v1.schema.json` ↔ `Sources/CSFeedbackKit/Payload/FeedbackPayload.swift`
- Samples: `Examples/configs/shizen.json`, `Examples/configs/grill.json`
- Local receiver: `node Examples/receiver.mjs`

Keep each schema and its Swift type in sync. Breaking payload changes mean `csfeedbackkit/v2`.

## Phases

1. **Core runtime (done).** Config loading (bundle, layered merge, `${NAME}`, validation that
   asserts in DEBUG and disables in Release), environment detection + gating, fields registry
   (`Feedback.session.provide`, `FeedbackContextProvider`, screen > session > static,
   declared-only, type checks), attachment collectors (device/app, tester identity, OSLogStore
   logs), payload builder. Screen trail is out of v1 (would need a `viewDidAppear` swizzle).
2. **Delivery (done).** HTTP destination, json + multipart, static headers + named async auth
   handlers, `Idempotency-Key`, file-backed outbox with backoff (flush on launch, foreground,
   network return), size budget (downscale screenshot → trim logs → never drop the note),
   2xx = delivered, keep response `id`.
3. **Composer (done).** Snapshotter (from Shizen's `LessonHostSnapshot`) + secure-field redaction,
   generic note sheet ported from Shizen's QA composer (context disclosure, Details section for
   missing required fields / tester prompt, note, tag chips, #screenshot/#logs toggles,
   Copy for agent), `FeedbackAppearance` (button colors, sheet + toast hooks),
   `Feedback.present(from:)`, SwiftUI `.feedbackContext` + `FeedbackButton`.
   Also added: `maxBodyBytes` (Phase 2), `copy.queuedToast` (Phase 3).

   Since added: per-destination `format` / `attachments` (inline, link, none) / `when`, request signing
   (standard-webhooks, openbot), `storage` uploads, and the on-device queue with a debug screen
   (failed notes are kept for manual resend).
4. **Screenshot trigger (done) + tray (not started).** `Feedback.installTriggers()` + config `triggers`.
   Tray: quick capture, review, submit as a session.
5. **Shizen adoption (in progress; Xcode builds, alongside the old note).** Bundle config, register `staff` auth + `staffAccess` check, lesson
   screens become context providers, `/api/client/content-qa/notes` accepts
   `csfeedbackkit/v1`, delete the old composer and screenshot shortcut.
6. **Grill app adoption.** TestFlight-only config, `userEmail` / `grillId` providers.
7. **Polish.** PencilKit markup, config reference. README and `Examples/Starter/` done.
8. **Distribution.** Own git repo so other projects can add it by URL (today it's a local path).
