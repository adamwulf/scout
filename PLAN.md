# Scout implementation plan

## Goal and scope

Build a small, usable single-account Help Scout CLI backed by a reusable Swift library. Success means offline tests and CLI smoke checks pass, independent plan and implementation reviews pass, and a user can authenticate, list inboxes/conversations, read threads, search, look up customers, use saved replies, save a draft, and send a new reply.

The initial repository is empty except for `.gitignore`. Consulted `iris-helper` and `hunch-helper` on 2026-11-07. Reuse their library/executable split, injected HTTP transport, library-owned rendering and validation, separate read-only command group, and offline tests. Avoid their multi-account and IMAP-specific complexity.

## API findings

- Use the Inbox API. OAuth client credentials is intended for internal integrations. Access tokens last two days; reuse them until expiration instead of requesting one per command.[^1]
- Use v3 conversation listing/search and customer listing, with cursor pagination. Search accepts field clauses rather than bare text and searches every status unless restricted. Exact email lookup is available through typed list filters.[^2][^3][^4]
- Use v3 conversation detail/thread reads; inboxes and saved replies remain v2. Thread lists must be fetched separately to avoid truncated embedded chats.[^5][^6]
- Replies use `POST /v2/conversations/{id}/reply`; explicitly set `draft: true` for drafts and `false` for sends. Return the new thread's `Resource-ID`. Status is explicit in the CLI (default active), because replies otherwise reopen conversations.[^7]
- Saved replies have a list endpoint (preview) and a detail endpoint (full HTML text), scoped to an inbox.[^8][^9]
- The documented publish operation applies to scheduled threads. Do not implement sending an existing unscheduled draft by assuming this endpoint supports it. Initial sends create new reply threads; drafts can be completed in Help Scout.[^10]
- Rate limiting is account-wide; 429 includes `X-RateLimit-Retry-After`. Surface a useful retry delay. Never automatically replay a write after a transport failure or 5xx, because it may already have succeeded.[^11]

## Phase 1: plan review

Commit this plan and get two independent reviews: API correctness/auth/data safety, and scope/architecture/usability. Fix meaningful issues before implementation. Clarify whether “userid” means Help Scout customer ID or an application-specific custom property. Default template source is Help Scout saved replies; confirm this fits.

## Phase 2: package, configuration, authentication

- Swift 6 package: `ScoutKit` library, `scout` executable, `ScoutKitTests`, `CLITests`. Only executable depends on Swift Argument Parser. No logging dependency or persistent customer-data store.
- Library owns configuration, HTTP, OAuth, models, pagination, input validation, reply construction, and output rendering. CLI parses options, invokes library methods, prints data to stdout and hints/errors to stderr.
- Load a single nearest `.env` by searching upward from cwd, then overlay nonempty process environment. Also support explicit `--env-file`. Parse basic KEY=value, optional export, quotes and comments without shell evaluation. Never inspect actual credential files during agent implementation: environment policy prohibits reading `.env`.
- Canonical names: `SCOUT_APP_ID`, `SCOUT_APP_SECRET`, optional `SCOUT_ACCESS_TOKEN`, optional `SCOUT_MAILBOX_ID`. Ask for existing key names only if different; never ask for secret values in chat.
- Client-credentials auth is the first supported flow; direct access token also works. Browser OAuth and refresh-token grants are deferred unless user needs them.
- Persist only obtained access token + expiry + app ID in a private single-account cache (`~/.config/scout/token.json`, directory 0700/file 0600). Process-supplied access token takes precedence and is not persisted. Cache expiry refresh and one reauthentication attempt after 401; no token values printed. Inject cache/transport/time for tests. `auth login` obtains/reuses token and validates with `/v2/users/me`; `auth status` validates and prints identity.
- Shared request execution builds encoded URLs, authenticates, decodes errors, rejects unexpected redirects, and reports HTTP status/request path/retry delay with secrets redacted. No automatic retries except one definite 401 after renewing client credentials.

Acceptance: mocked token exchange/reuse/expiry/401, environment precedence, form/query encoding (including `+`), cache permissions, and sanitized errors are tested. Builds without credentials.

## Phase 3: read workflows

Command surface (IDs always Help Scout API IDs, not conversation numbers):

```
scout auth login|status
scout inboxes
scout list [--mailbox ID] [--status active|pending|closed|spam|all] [--limit N]
scout show CONVERSATION_ID
scout search 'subject:refund AND status:active' [--limit N]
scout customers --email EMAIL [--limit N]
scout customers --query QUERY [--limit N]
scout customer CUSTOMER_ID
scout templates --mailbox ID
scout template TEMPLATE_ID --mailbox ID
scout ro <any read command above except auth login>
```

- Lists default to 50 items, paginate until limit, and return an explicit continuation cursor/page with instructions so results beyond the limit remain reachable. `show` fetches all thread pages.
- List formats: table, json, jsonl, id. Detail formats: markdown, json. Library renderers are pure. JSON list output has stable items + continuation metadata; jsonl/id emit just rows and continuation hints go to stderr. Preserve customer properties and thread metadata in JSON without requiring every possible API field to be modeled.
- Read-only namespace contains no draft/send commands, enforced by a marker protocol and CLI parse tests. Auth/cache writes may occur during reads; “read-only” means no Help Scout content mutation.

Acceptance: fixture decoding, pagination and limits, customer query encoding, full thread reads, output formats, CLI parsing, and read-only command membership tested offline.

## Phase 4: drafts, sends, templates

```
scout draft CONVERSATION_ID --body 'Thanks!'
scout draft CONVERSATION_ID --body-file reply.html [--html]
scout draft CONVERSATION_ID --template TEMPLATE_ID
scout send CONVERSATION_ID --body-file reply.txt [--status closed]
```

- Exactly one source: `--body`, `--body-file PATH` (`-` reads stdin), or `--template ID`. Empty bodies fail before requests. Plain text is HTML-escaped and newlines converted; `--html` accepts intentional HTML. No editor integration.
- Fetch conversation first and use its canonical ID, primary customer and inbox. Template IDs resolve in that inbox. Sending is an explicit separate command; no additional confirmation flag. Automated implementation checks never send a real reply.
- Template command exports full source text for manual adaptation. Direct template use supports literal templates; fail clearly on unresolved Help Scout variable syntax instead of sending placeholders. No custom template engine in v1.
- Report draft/sent state and returned thread ID. On uncertain network failure, instruct user to inspect conversation before retrying.

Acceptance: assert captured requests have correct customer, inbox template lookup, escaped or HTML body, explicit draft flag, status, and no repeated POST after uncertain failure. Test empty/conflicting body sources and unresolved template variables.

## Phase 5: implementation review and handoff

- README: build/run, credential key names, cache location, supported commands, search examples, draft/send distinction, limits and continuation, template limitations.
- Contributor instructions with library/CLI boundary and test commands. Small `skill/scout/SKILL.md` agent usage guide.
- Run `swift test`, release build, CLI help/parsing/output smoke checks without credentials.
- Commit, run two independent implementation reviewers, fix every realistic code issue and meaningful documentation issue, repeat code review after fixes, retire reviewers.
- Live auth/read smoke checks are a user follow-up while `.env` reads are prohibited in this session. Clearly report that live API behavior remains unverified. No live draft/send tests without a specified test conversation.

Deferred: multi-account, browser OAuth, local template library, attachment upload/download, contact editing, new outbound conversations, scheduling, existing-draft publish, bulk actions, webhooks, reports, sync, and migrations.

## Sources

[^1]: [Help Scout authentication](https://developer.helpscout.com/mailbox-api/overview/authentication/)
[^2]: [List conversations v3](https://developer.helpscout.com/mailbox-api/endpoints/conversations/list-v3/)
[^3]: [Search conversations v3](https://developer.helpscout.com/mailbox-api/endpoints/conversations/search-v3/)
[^4]: [List customers v3](https://developer.helpscout.com/mailbox-api/endpoints/customers/list-v3/)
[^5]: [List threads v3](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/list-v3/)
[^6]: [List inboxes](https://developer.helpscout.com/mailbox-api/endpoints/inboxes/list/)
[^7]: [Create reply thread](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/reply/)
[^8]: [List saved replies](https://developer.helpscout.com/mailbox-api/endpoints/inboxes/saved_Replies/saved-replies-list/)
[^9]: [Get saved reply](https://developer.helpscout.com/mailbox-api/endpoints/inboxes/saved_Replies/saved-replies-get/)
[^10]: [Publish thread schedule](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/schedule/publish/)
[^11]: [Rate limiting](https://developer.helpscout.com/mailbox-api/overview/rate-limiting/)
