# Draft lifecycle implementation plan

## Goal and acceptance criteria

Extend the existing `scout draft` command to create or update, send, and delete a selected existing draft. Keep the executable thin and implement selection and HTTP workflows in ScoutKit. The user requested this sequence: plan file, one Sol agent plan review, implementation, then two independent Sol agent implementation reviews.

- [ ] One Sol reviewer approves the plan and API feasibility.
- [ ] Implement the agreed interface with offline selection, request, failure, and CLI parsing coverage.
- [ ] Update README.md and skill/scout/SKILL.md.
- [ ] `swift test --disable-sandbox` and `swift build --disable-sandbox -c release` pass; help and invalid-input smoke checks pass without credentials.
- [ ] Commit implementation; two independent Sol reviewers approve; fix realistic code issues and meaningful documentation issues and repeat code review after code fixes.
- [ ] Retire reviewers and report commits, checks, and live API limitations.

## Agreed command interface

```sh
scout draft CONVERSATION_ID --body 'Reply text'
scout draft CONVERSATION_ID --body-file reply.txt
scout draft CONVERSATION_ID --template TEMPLATE_ID
scout draft CONVERSATION_ID --send
scout draft CONVERSATION_ID --delete
scout draft CONVERSATION_ID --thread THREAD_ID --send
```

Exactly one action is required: send, delete, or one body source. Reject combinations of send/delete/body sources before loading credentials or reading a body file/stdin. `--html` only applies to literal body/file input, not send/delete/template. Validate positive conversation and optional thread IDs. Keep `scout send` as the existing new-reply operation; do not add status or scheduling options to draft in this change. All draft actions remain unavailable under `ro`.

Selection uses all thread pages for the specified conversation. Count every thread in state `draft` when deciding zero/one/multiple, so an unsupported draft is never silently ignored to create another. For this reply-focused change, only type `message` is a supported mutation target; reject other types, including `forwardparent`/`forwardchild`, with an explicit unsupported-type error. Do not test for a nonexistent `reply` type. The API exposes these type values, state and optional schedule metadata.[^1]

- No draft: body input creates one; send/delete fail with a no-draft error.
- One draft: select it automatically.
- Multiple drafts: fail with candidate IDs and require `--thread`.
- Explicit thread ID: require that exact draft in the conversation; never fall back to creation.

Do not assume the service enforces one draft per conversation. Receipts identify conversation ID, thread ID and operation (created/updated/sent/deleted). Display thread IDs in Markdown `show` if not already present. No body text in receipts/errors.

## API findings and feasibility gate

Creation uses `POST /v2/conversations/{id}/reply` with `draft: true`, reusing the existing body validation and conversation-status preservation.[^2]

Update uses `PATCH /v2/conversations/{id}/threads/{threadId}` with the JSON object `{"op":"replace","path":"/text","value":"..."}`. Only the body changes; do not reconstruct attachments or recipients. Thread editing requires an administrator or enabled thread editing.[^3]

Sending uses the existing thread rather than copying its body to a new reply. The documented publish API is for scheduled threads. For an already scheduled draft, publish it directly with `PATCH .../schedule`, `{"op":"replace","path":"/state","value":"published"}`. For an unscheduled draft, schedule it first with `PUT .../schedule` and then immediately publish it. Scheduling requires a future ISO 8601 time and `unscheduleOnCustomerReply`; it optionally accepts `sendAsCreator`.[^4][^5]

Proposed unscheduled-send choices, pending Adam's decision: a time 24 hours in the future, `unscheduleOnCustomerReply: true`, and `sendAsCreator: false` (the API default, sending as the acting identity). Help Scout describes scheduled replies as sent by the user who schedules them.[^7] Inject a clock for deterministic tests. The future timestamp provides time to inspect a partial failure; it is not a guarantee against a later automatic send. Never silently schedule near-now as a substitute for publishing. A process interruption between scheduling and publication can leave a queued send without an error message. This two-request contract must be explained in command help and documentation, not only on caught errors.

If scheduling or publication fails or times out, stop without automatic retry, rollback, or another send. Distinguish the failed phase and known versus uncertain outcomes: a rejected schedule was not published by this command; a timed-out/5xx schedule may be queued; a rejected publication can leave the confirmed schedule active; a timed-out/5xx publication may already have sent or may still be queued. Include conversation/thread IDs and direct the user to inspect the thread and cancel any remaining schedule in Help Scout before retrying. If the draft was already scheduled, preserve that schedule and sender configuration. Validate existing draft body for unresolved variables before any send mutation without rewriting its HTML. Reject missing or whitespace-only bodies and ordinary empty editor HTML (such as `<p><br></p>` or `&nbsp;`); preserve image-only or attachment-bearing drafts as meaningful content. Keep this validation local to existing-draft sending. Do not change conversation status separately, and do not promise publication preserves status: the schedule/publish endpoints do not document the resulting conversation status. Creation preserves status explicitly and body updates write only text.

**Unresolved deletion endpoint:** initial research did not find a documented endpoint that deletes a draft thread. `DELETE .../schedule` explicitly only unschedules the thread, leaving a draft.[^6] `DELETE /conversations/{id}` is not an acceptable substitute. The plan reviewer must independently check deletion support. Do not invent a thread DELETE endpoint, hide a draft, clear its text, or delete a conversation to simulate draft deletion. If no documented operation is available, bring this limitation to Adam for a decision before treating `--delete` as implementable. Continue only independently authorized work while a decision is pending.

## Plan review outcome — 2026-11-08

Sol reviewer `agent-86c51851` requested changes. Independent research likewise found no documented draft-thread deletion endpoint. Decisions pending from Adam: defer deletion (recommended) or reserve `--delete` with an explicit unsupported-operation error; accept the documented two-step send contract or defer unscheduled sends. Selection types, HTML-empty validation, partial-send diagnostics, and limits on status guarantees are clarified above. Implementation remains pending resolution and plan re-review by this same reviewer.

## Implementation shape

1. Add focused ScoutKit draft lifecycle methods plus shared draft selection. Preserve `createDraft` as the explicitly named library creation primitive; add a save/upsert method for CLI use. Reuse conversation/thread paging, HTTP errors, template lookup and ReplyBody validation. Extract small helpers where this avoids duplicating existing reply preparation.
2. Refactor CLI body options so the draft command can validate its combined action while the existing send command still requires exactly one body source. Keep validation reusable and ensure send/delete do not evaluate content providers.
3. Fetch and validate the target conversation before writes, retaining existing merged-ID behavior. Fully enumerate threads before selecting. Use the returned conversation for template lookup/status rather than redundant reads where practical.
4. Handle successful 204 responses without decoding a nonexistent body. Retain no-automatic-replay behavior for uncertain writes; no custom retries, migrations, or compatibility layer.
5. Document the new create/update behavior, explicit thread selection, commands, permissions, scheduled-send mechanism and partial-failure recovery. Remove statements that existing drafts cannot be published through Scout once implemented. Update the installed skill only if explicitly requested; repository skill is in scope.

## Validation

Use injected transport and safe fixture data only; no real credentials, customer writes, sends, or draft deletion during implementation.

- Zero/one/multiple draft selection, explicit ID success and absent/wrong-state/wrong-type rejection; drafts found on later pages.
- Creation only for zero drafts with no explicit ID; preserve status and existing body/template validation.
- Updating sends exactly the expected text PATCH; no POST, send, status change, attachment or recipient payload.
- Sending preserves the thread ID; unscheduled PUT then publish PATCH in order; scheduled draft only publishes. Verify schedule time/fields using a fixed clock.
- Missing/empty/unresolved draft body fails before scheduling/publishing.
- HTTP failures at each step: no downstream publish after failed scheduling, no replay after timeout/5xx; actionable partial-send error; no success receipt for failure.
- Deletion tests depend on resolving the feasibility gate; no fake implementation against an undocumented endpoint.
- Parse all valid actions/options, every conflicting action/source combination, missing action, invalid IDs, invalid html combinations, and read-only rejection. Ensure original `scout send` parsing remains strict.
- JSON receipt operation/IDs and Markdown draft ID visibility.

## Scope limits

No general scheduling command, separate status-change requests on existing-draft sends, attachment editing, recipient editing, new outbound conversations, bulk actions, UI automation, credential changes, or migration work. Normal read/write concurrency is not made atomic by the API; do not add speculative locking or retries. Live API behavior remains unverified until Adam selects a test conversation and authorizes live tests.

## Sources

[^1]: [Help Scout: List threads v3](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/list-v3/)
[^2]: [Help Scout: Create reply thread](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/reply/)
[^3]: [Help Scout: Update thread](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/update/)
[^4]: [Help Scout: Update thread schedule](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/schedule/update/)
[^5]: [Help Scout: Publish thread schedule](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/schedule/publish/)
[^6]: [Help Scout: Delete thread schedule](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/schedule/delete/)
[^7]: [Help Scout: Schedule a reply to send later](https://docs.helpscout.com/article/1577-schedule-a-reply-to-send-later)
