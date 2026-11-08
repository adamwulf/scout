# Scout implementation plan

## Goal and scope

Build a small, usable single-account Help Scout CLI backed by a reusable Swift library. Success means offline tests and CLI smoke checks pass, independent plan and implementation reviews pass, and a user can authenticate, list inboxes/conversations, read threads, search, look up customers, use saved replies, save a draft, and send a new reply.

The initial repository is empty except for `.gitignore`. Consulted `iris-helper` and `hunch-helper` on 2026-11-07. Reuse their library/executable split, injected HTTP transport, library-owned rendering and validation, separate read-only command group, and offline tests. Avoid their multi-account and IMAP-specific complexity.

## API findings

- Use the Inbox API. OAuth client credentials is intended for internal integrations. Access tokens last two days; reuse them until expiration instead of requesting one per command.[^1]
- Use v3 conversation listing with cursor pagination and exact email filtering.[^2] Search accepts field clauses rather than bare text and searches every status unless restricted.[^3] Customer listing also uses cursors and supports an email filter; its documentation does not promise exact matching, so return server results unchanged and describe this as an email filter.[^4]
- Use v3 conversation detail and thread reads.[^12][^5] Fetch threads separately because embedded chats can be truncated.[^3] Inboxes and saved replies remain v2.[^6][^8][^9] Single-customer lookup also uses v2.[^13]
- Replies use `POST /v2/conversations/{id}/reply`; explicitly set `draft: true` for drafts and `false` for sends. Return the new thread's `Resource-ID`. Preserve the fetched conversation status when drafting; sends default to active with an optional explicit status, because replies otherwise reopen conversations.[^7]
- Saved replies have a list endpoint (preview) and a detail endpoint (full HTML text), scoped to an inbox.[^8][^9]
- The documented publish operation applies to scheduled threads. Do not implement sending an existing unscheduled draft by assuming this endpoint supports it. Initial sends create new reply threads; drafts can be completed in Help Scout.[^10]
- Rate limiting is account-wide; 429 includes `X-RateLimit-Retry-After`. Surface a useful retry delay. Never automatically replay a write after a transport failure or 5xx, because it may already have succeeded.[^11]

## Phase 1: plan review

Commit this plan and get two independent reviews: API correctness/auth/data safety, and scope/architecture/usability. Fix meaningful issues before implementation. Adam confirmed saved replies and client-credentials auth on 2026-11-07; there are no existing credential variable names to preserve. Allume user IDs are not stored in Help Scout; user-ID lookup is explicitly out of scope. An Allume CLI can resolve an ID to email, then Scout can search that email.

## Phase 2: package, configuration, authentication

- Swift 6 package: `ScoutKit` library, `scout` executable, `ScoutKitTests`, `CLITests`. Only executable depends on Swift Argument Parser. No logging dependency or persistent customer-data store.
- Library owns configuration, HTTP, OAuth, models, pagination, input validation, reply construction, and output rendering. CLI parses options, invokes library methods, prints data to stdout and hints/errors to stderr.
- Load a single nearest `.env` by searching upward from cwd, then overlay nonempty process environment. Also support explicit `--env-file`, including running from outside the project. Discovery stops at the first file even when it lacks Scout settings; missing-credential errors identify the selected file or report none found. Parse basic KEY=value, optional export, quotes and comments without shell evaluation. Never inspect actual credential files during agent implementation: environment policy prohibits reading `.env`.
- Canonical names: `SCOUT_APP_ID`, `SCOUT_APP_SECRET`, optional `SCOUT_ACCESS_TOKEN`, optional `SCOUT_INBOX_ID`. Ask for existing key names only if different; never ask for secret values in chat.
- Client-credentials auth is the first supported flow; direct access token also works. Browser OAuth and refresh-token grants are deferred unless user needs them.
- Both `.env` and process-environment access tokens count as explicit tokens. Send token requests as form-encoded POST bodies, never query strings. A final 401 explains that the app owner must be active and invited; token renewal cannot fix an inactive owner.[^1]
- Persist only obtained access token + expiry + app ID in a private single-account cache (`~/.config/scout/token.json`, directory 0700/file 0600), using private permissions at creation. Process-supplied access token takes precedence and is not persisted; a rejected explicit token reports instructions to unset/update `SCOUT_ACCESS_TOKEN`, never silently switches identity. Cache expiry refresh and one reauthentication attempt after 401; invalidate rejected cached tokens. No token values printed. Inject cache/transport/time for tests. `auth login` obtains/reuses token and validates with `/v2/users/me`; `auth status` validates and prints identity.
- Shared request execution builds encoded URLs, authenticates, decodes errors, and reports HTTP status/path without query strings plus retry delay with secrets redacted. Disable automatic HTTP redirects. For merged conversation 301, report the trusted Help Scout destination ID and require rerunning with that ID rather than silently changing a write target. Other redirects fail explicitly. No automatic retries except one definite 401 after renewing client credentials. Give useful 403 permission and 412 locked-conversation explanations.
- Merge handling is based on the documented v2 behavior and conservatively applies to v3: a GET conversation 301 must point to HTTPS `api.helpscout.net` and a v2/v3 conversation-ID path; reject other destinations. Both show and writes stop with the new ID. Test that no POST follows a merge response. Reply 404 explains possible merge/deletion; 412 explains thread limit or company locking policy.[^14][^7]

Acceptance: mocked token exchange/reuse/expiry/401, environment precedence, form/query encoding (including `+`), cache permissions at creation, and sanitized errors are tested. Test 429 retry-delay reporting without replay. Builds without credentials.

## Phase 3: read workflows

Command surface (IDs always Help Scout API IDs, not conversation numbers):

```
scout auth login|status
scout inboxes [--page N]
scout list [--inbox ID] [--status active|pending|closed|spam|all] [--cursor CURSOR]
scout show CONVERSATION_ID
scout search 'subject:refund AND status:active' [--cursor CURSOR]
scout customers --email EMAIL [--cursor CURSOR]
scout customers --query QUERY [--cursor CURSOR]
scout customer CUSTOMER_ID
scout templates [--inbox ID]
scout template TEMPLATE_ID [--inbox ID] [--format raw|markdown|json]
scout ro <any read command above except auth login>
```

- Lists return one complete API page; no arbitrary item limit that could discard part of a page. Cursor/page flags allow continuation. Conversations and customers use cursors, inboxes and threads use page numbers, and saved replies return a plain array. Print a complete shell-quoted next command preserving filters to stderr in every format; omit it on the last page. `show` fetches all thread pages.
- List formats: table, json, jsonl, id. Detail formats: markdown, json. Library renderers are pure. JSON list output has stable items + continuation metadata; jsonl/id emit just rows and continuation hints go to stderr. Preserve customer properties and thread metadata in JSON without requiring every possible API field to be modeled.
- `show` renders oldest first, with each thread labeled author, timestamp, type, and state (including drafts/hidden). Small deterministic HTML-to-text conversion provides readable output; JSON retains original HTML. Conversation tables show both API ID and human conversation number.
- `template` defaults to raw HTML text with no wrapper, so it can be saved to a file and edited. `--inbox` overrides the environment default; templates require one or the other. Search ignores that default and uses only its query, including any `inboxId:` restriction. Reject obvious bare-text searches locally with a valid field-query example; do not recreate the server query parser.
- Customer lookup supports Help Scout customer ID and documented email/name queries. `customers --query` expects advanced field syntax, not free text. Application-specific user-ID lookup is out of scope per Adam; do not guess a property query or scan the whole customer directory. A customer-list 403 explains the Contacts and Companies directory permission.[^4]
- Read-only namespace contains no draft/send commands, enforced by a marker protocol and CLI parse tests. Auth/cache writes may occur during reads; “read-only” means no Help Scout content mutation.

Acceptance: fixture decoding, full-page continuation with runnable hints, customer query encoding, full thread reads, labeled rendering, output formats, CLI parsing, and read-only command membership tested offline.

## Phase 4: drafts, sends, templates

```
scout draft CONVERSATION_ID --body 'Thanks!'
scout draft CONVERSATION_ID --body-file reply.html --html
scout draft CONVERSATION_ID --template TEMPLATE_ID
scout send CONVERSATION_ID --body-file reply.txt [--status closed]
```

- Exactly one source: `--body`, `--body-file PATH` (`-` reads stdin), or `--template ID`. Empty bodies fail before requests. Plain text is HTML-escaped and newlines converted; `--html` accepts intentional HTML. No editor integration.
- Saved-template bodies are treated as HTML, as shown in the documented example, and used unchanged; reject redundant `--html` with `--template`. Use email `text`, not `chatText`.[^9] Check every body source for unresolved `{%...%}` template markers before a POST, including exported/edited template files.[^15]
- Fetch conversation first and use its ID, primary customer and inbox. If merged, stop and report the new ID for the user to inspect and rerun. Template IDs resolve in that inbox. Sending is an explicit separate command; no additional confirmation flag. Automated implementation checks never send a real reply.
- Template command exports full source text for manual adaptation. Direct template use supports literal templates; fail clearly on detected unresolved variables instead of sending placeholders. No custom template engine in v1. Document `scout template ID > reply.html`, edit, then `scout draft CID --body-file reply.html --html`.
- Report draft/sent state and returned thread ID. On uncertain network failure, instruct user to inspect conversation before retrying.

Acceptance: assert captured requests have correct customer, inbox template lookup, escaped or HTML body, explicit draft flag, status, and no repeated POST after uncertain failure. Test empty/conflicting body sources, draft status preservation, unresolved variables in body/file/template inputs, and rejecting --html with --template.

## Phase 5: implementation review and handoff

- README: build/run, credential key names, explicit env-file use outside project, cache location, supported commands, search examples (all statuses and inboxes by default), draft/send distinction, full-page continuation, template limitations. Identify API IDs in conversation URLs and clarify replies are authored by the `auth status` identity.
- README and skill search examples quote email values: `scout search 'email:"jane@my-company.com"'`. Explain that reserved characters (including plus and hyphen) require quoted values. Also show `contactId:123` and `number:1234`; bare-text validation must accept these field clauses.[^3]
- Contributor instructions with library/CLI boundary and test commands. Small `skill/scout/SKILL.md` agent usage guide: use `ro` for reads, draft by default, send only on explicit user instruction.
- Run `swift test`, release build, CLI help/parsing/output smoke checks without credentials.
- Commit, run two independent implementation reviewers, fix every realistic code issue and meaningful documentation issue, repeat code review after fixes, retire reviewers.
- Live auth/read smoke checks are a user follow-up while `.env` reads are prohibited in this session. Clearly report that live API behavior remains unverified. No live draft/send tests without a specified test conversation; include confirming draft status preservation in that follow-up.

Deferred: multi-account, browser OAuth, local template library, attachment upload/download, contact editing, new outbound conversations, scheduling, existing-draft publish, bulk actions, webhooks, reports, sync, and migrations.

## Implementation outcome — 2026-11-07

All five phases are complete. The implementation is committed on `agent/helpscout-cli`; live validation remains the explicitly documented follow-up.

- Plan reviews: `agent-f1d6afc7` and `agent-48431bf1` approved the revised plan at `69a875b`.
- Auth/config/HTTP reviews: `agent-ef29ddf0` and `agent-8427f9c9` approved after fixing empty dotenv values followed by comments and adding the error-response source citation.
- Formatting/body reviews: `agent-cc6d0d0f` and `agent-8427f9c9` approved after fixing tagless HTML entity decoding, rich-text list bullets, and plain-text customer notes.
- Final implementation reviews: `agent-68e2980e` and `agent-5286b781` approved `16d42e8`. Both independently ran the 112-test suite and release build. The usability reviewer also checked help, rejected read-only writes, bare-text search validation, README examples and citations.
- Verification: `swift test --disable-sandbox` passes (108 library tests + 4 CLI tests); `swift build --disable-sandbox -c release` succeeds; root and send help smoke checks pass. Tests never use real credentials or send real messages.
- Environment adjustment: configuration fixtures use `scout-fixture.env` through an internal test-only discovery override because this sandbox blocks all `.env` files, including synthetic ones. Public discovery still uses `.env`.
- Deferred review notes: show/customer help lists `raw` among the shared enum values, but explicitly describes markdown/json and rejects raw during parsing. This cosmetic help mismatch does not affect supported commands. Extra CLI continuation-assembly tests were suggested but not required: library shell quoting/continuation and CLI parse coverage passed.
- Remaining live checks: authenticate, list/read/search/customer/template results, actual cursor and thread pagination behavior, merged conversation response, and draft status preservation on a user-selected test conversation. No live API calls or real sends were performed.

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
[^12]: [Get conversation v3](https://developer.helpscout.com/mailbox-api/endpoints/conversations/get-v3/)
[^13]: [Get customer](https://developer.helpscout.com/mailbox-api/endpoints/customers/get/)
[^14]: [Get conversation v2: merged conversations](https://developer.helpscout.com/mailbox-api/endpoints/conversations/get/)
[^15]: [Help Scout variable syntax](https://docs.helpscout.com/article/468-variables)
