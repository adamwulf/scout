# Scout

A single-account Help Scout client: `ScoutKit` contains the logic; `scout` is a thin Swift Argument Parser executable.

## Installation

Requires Swift 6 and macOS 13 or later.

Install globally using [Mint](https://github.com/yonaskolb/Mint):

```sh
mint install adamwulf/scout@main --force
```

Mint links `scout` into `~/.mint/bin`, so make sure that directory is on your PATH. `--force` reinstalls even if `scout` is already installed, which is how you pick up new commits on `main`.

## Build from source

```sh
swift build -c release
swift test
.build/release/scout --help
```

In a sandboxed agent workspace where SwiftPM reports `sandbox_apply: Operation not permitted`, use `swift build --disable-sandbox -c release` and `swift test --disable-sandbox`. These flags affect SwiftPM's nested sandbox, not workspace access permissions.

Put `.build/release/scout` on your PATH to use the examples below.

## Authentication

Create a Help Scout OAuth app under **Your Profile → My apps**. For a single-account internal tool, Scout uses the client-credentials flow. The app owner's identity determines inbox access and authors replies; `scout auth status` displays that identity.[^1][^2]

Copy `.env.example` to `.env` yourself and fill in:

```dotenv
SCOUT_APP_ID=your_app_id
SCOUT_APP_SECRET=your_app_secret
# Optional default inbox for list/templates/template:
SCOUT_INBOX_ID=
# Optional explicit token; usually leave unset when using app credentials:
SCOUT_ACCESS_TOKEN=
```

```sh
scout auth login
scout auth status
scout ro inboxes
scout ro list --inbox 123
```

Scout reads `.env` files from the current directory upward and stops at the first one that sets any of `SCOUT_APP_ID`, `SCOUT_APP_SECRET` or `SCOUT_ACCESS_TOKEN`. A closer `.env` without Scout credentials is skipped in favor of a parent's, and file credentials always come from that one file, so the app ID and secret are never mixed across files. `SCOUT_INBOX_ID` may come from that file or a nearer one. If the process environment already supplies complete credentials, only the nearest `.env` is read, so put `SCOUT_INBOX_ID` there or in the environment. Empty values such as `SCOUT_APP_ID=` count as unset. Nonempty process environment values override file values. Basic `KEY=value`, optional `export`, single/double quotes, and comments are supported; no shell expressions or variable interpolation run. Errors identify the files read and missing key names without printing secret values.

From another directory, use an explicit path **after the leaf command**:

```sh
scout ro inboxes --env-file /path/to/scout/.env
```

An explicit `SCOUT_ACCESS_TOKEN` from either source takes precedence. If rejected, Scout tells you to update or unset it; it never silently changes identity by falling back to app credentials. Browser OAuth and refresh-token grants are not implemented.

Tokens obtained with app credentials are cached at `~/.config/scout/token.json`, with directory mode 0700 and file mode 0600. Scout reuses them until shortly before expiry and renews once on a 401. `ro` means no Help Scout content changes; reads may create or update this local token cache.

Every read command is also available at the root: `scout templates` and `scout ro templates` run the same implementation with the same options and output. The `ro` group rejects write commands.

## Read and search

```sh
scout ro inboxes --format table
scout ro list --inbox 123 --status all
scout ro show 987654 --format md
scout ro search 'subject:refund AND status:active'
scout ro search 'email:"jane+test@my-company.com"'
scout ro search 'contactId:456'
scout ro search 'number:1234'
scout ro customers --email jane+test@my-company.com
scout ro customers --query 'firstName:Jane'
scout ro customer 456 --format json
```

Commands take **API IDs**, not the `#number` displayed next to a conversation. The API ID is the numeric conversation identifier in its Help Scout URL. Tables show both `ID` and `NUMBER`; use `search 'number:1234'` to find an API ID from a conversation number.[^3]

`list` defaults to active conversations and honors `SCOUT_INBOX_ID`. `search` has no default inbox or status restriction: add `inboxId:123` or `status:active` to its query. It accepts field clauses rather than bare words. Quote values containing reserved characters, including `+` and `-`; Scout handles URL encoding. Queries are limited to 500 characters.[^3]

`customers --email` returns Help Scout's email-filter results unchanged; it does not impose its own exact-match filter. `customers --query` uses Help Scout's advanced customer query syntax. The customer list requires the Contacts and Companies directory permission.[^4] Allume-specific user IDs are out of scope: resolve the ID to an email with Allume, then use that email in Scout.

Lists return **one complete API page**. When more results exist, stderr prints a runnable `Next:` command preserving filters, output format and `--env-file`. Run that command to continue. Conversations/search/customers use `--cursor`; inboxes use `--page`. If a cursor is rejected, restart without it. `show` automatically fetches all thread pages and displays threads oldest first, including notes, activities and clearly labeled drafts.

List formats are `table` (default), `json`, `jsonl`, and `id`. Conversation tables from `list` and `search` end with Help Scout's message preview, shortened to 200 columns. JSON lists have `items`, `nextCursor` and `nextPage`; JSONL/ID contain only rows. Detail formats are `md` (default) and `json`. JSON preserves original HTML and optional API fields; Markdown provides a small HTML-to-text conversion. Hints and errors go to stderr.

## Attachments

```sh
scout ro show 987654 -o attachments
scout ro attachments 987654 -o attachments
scout ro attachments 987654 -o attachments --attachment 12345
```

`show` Markdown lists each thread's attachments with their attachment IDs. Help Scout serves attachment contents only through the authenticated API, so Markdown can only display files saved locally.[^15] `show -o DIR` (`--output-dir`) also downloads every attachment and links each file after its thread body; images are embedded as `![name](DIR/file)`. Links use `DIR` as written (with `~` expanded), so a relative directory works when the Markdown is saved in the current directory. `-o` requires Markdown output; with `--format json`, download separately with `attachments`.

`attachments` requires `-o DIR` and prints one saved path per line; `--attachment ID` saves only that attachment. The directory is created if missing. Files are named `<attachment ID>-<filename>`. Control characters are removed, and path separators, `:`, `<`, `>`, `#`, `?` and `%` become `_`. A file therefore never lands outside `DIR`, and Markdown links to it work. Downloading again atomically replaces the same file. Attachments Help Scout flags as viruses are skipped, and requesting one with `--attachment` is an error. Skips and failures are reported on stderr. A failed download does not stop the others, and the command exits nonzero if any failed. Both commands only write local files, so they are available under `ro`.

## Draft and send replies

```sh
scout draft 987654 --body 'Thanks for reporting this. We are investigating.'
scout draft 987654 --body-file reply.txt
scout draft 987654 --body-file reply.html --html
scout draft 987654 --body-file - < reply.txt
scout draft 987654 --thread 123456 --body-file reply.txt
scout send-draft 987654
scout send-draft 987654 --thread 123456
scout send 987654 --body-file reply.txt --status closed
```

`draft` never sends or publishes, and it refuses to edit a draft that is already scheduled (shown with `Scheduled for` in `scout ro show`), so it can be allowed without allowing sends. Sending lives in two separate commands: `send-draft` publishes an existing draft and `send` creates a new reply. `draft` and `send` each require exactly one body source (`--body`, `--body-file`, `--template`); `send-draft` accepts no body options. Plain text is trimmed at the outer edges, HTML-escaped and converted to HTML line breaks. Use `--html` for intentional HTML. Empty or invalid UTF-8 bodies fail. Reading stdin is explicit (`--body-file -`) and is rejected when stdin is a terminal.

With body input, `draft` creates a server-side reply draft if none exists, preserving the conversation's status.[^2] If one draft exists, it updates that draft's text and leaves recipients and attachments untouched. A scheduled draft is refused before any write, because changing its text would change a reply Help Scout sends automatically; change or unschedule it in Help Scout. Updating uses Help Scout's thread editing endpoint and requires administrator access or enabled thread editing.[^11] If multiple drafts exist, use `--thread ID`; `scout ro show` displays thread IDs. An explicit ID must belong to a draft in that conversation; it never falls back to creation. Only reply drafts (API type `message`) are supported; edit or send forward drafts in Help Scout. Draft deletion is deferred because no public draft-thread deletion endpoint was found; delete drafts in Help Scout.

`send-draft` sends the selected existing draft without rewriting its body, using the same `--thread ID` selection as `draft`. Missing drafts, empty content, and unresolved variables fail before sending. An unscheduled draft is scheduled for 24 hours ahead with cancellation on a customer reply and sent as the authenticated user, then immediately published; an already scheduled draft is published directly, preserving its existing schedule and sender settings.[^12][^13][^14] This is a two-request operation: **if publication fails or the process stops between requests, a future send can remain queued**. If a publication response is lost, the reply may already have sent. Errors describe the failed step and possible outcome. Inspect the conversation and cancel any remaining schedule in Help Scout before retrying. Scout does not automatically retry uncertain writes or roll back schedules. `send-draft` offers no `--status` option and issues no separate status change; Help Scout may apply pending draft actions on publication.

`send` immediately creates a **new** reply thread; its default status is `active`, which can reopen a closed conversation. Use `--status closed`, `pending`, or `spam` when appropriate.[^2]

`draft` and `send-draft` print a JSON receipt containing `conversationID`, `threadID`, and `operation` (`created` or `updated` for `draft`; `sent` for `send-draft`). `send` receipts contain `conversationID`, `threadID`, and `draft: false`. Creation may succeed without returning a thread ID; inspect the conversation instead of repeating the write. If a write times out or returns a server error, inspect the conversation before retrying: it may already have succeeded. Scout never automatically retries an uncertain write. A definite 401 with app credentials can be retried once after token renewal.

Merged conversations stop with the destination ID; inspect it and rerun explicitly. Rate limits report a retry delay without automatic replay. Locked conversations and permission errors include an explanation.

## Mark conversation status

```sh
scout mark spam 987654
scout mark closed 987654
scout mark active 987654
scout mark pending 987654
```

`mark <status> <id>` changes the whole conversation status without creating or sending a reply, using the Help Scout update endpoint.[^6] Use `closed` to archive a conversation and `active` to reopen it. The ID must be a Help Scout API conversation ID. This write command is unavailable under `scout ro`.

Marking spam trains Help Scout to route future conversations from that sender to Spam. Conversations left in Spam are permanently purged 30 days after their last action. Use Help Scout’s **Unmark as Spam** action to reverse an accidental spam classification.[^7]

Success prints a JSON receipt with `conversationID` and `status`. Merged conversations require an explicit rerun with the destination ID. After a timeout or server error, inspect the conversation before retrying; Scout never automatically replays an uncertain write.

## Saved replies / templates

```sh
scout ro templates --inbox 123
scout ro template 555 --inbox 123 > reply.html
# Edit reply.html, replacing any variables with literal text.
scout draft 987654 --body-file reply.html --html
# Literal templates can be used directly; the conversation determines its inbox:
scout draft 987654 --template 555
```

`templates` and `template` use `--inbox` or `SCOUT_INBOX_ID`. `template` defaults to raw email HTML, without a title or JSON wrapper; it also supports `--format md|json`. A raw export adds a final newline only if missing.

Create, update, and delete saved replies with the following root-only commands. They create with POST,[^8] update with PUT,[^9] and delete with DELETE.[^10]

```sh
scout template-create --inbox 123 --name 'Greeting' --body 'Hi {%customer.firstName,fallback=there%}!'
scout template-update 555 --inbox 123 --name 'Updated greeting'
scout template-update 555 --inbox 123 --body-file reply.html --html
scout template-delete 555 --inbox 123
# Chat content is plain text; include chat-only replies when listing:
scout template-create --inbox 123 --name 'Chat greeting' --chat-text 'Hi there!'
scout templates --inbox 123 --include-chat --format json
```

All three write commands use `--inbox` or `SCOUT_INBOX_ID` and return a JSON receipt. Create requires `--name` and an email body or `--chat-text` (or both). Choose `--body` or `--body-file`, including `--body-file -` for standard input. Email bodies are escaped plain text unless `--html` is specified; saved-reply variables are allowed. The library's `text` argument takes email HTML directly.

Update accepts any combination of name, email body, and chat text. It reads the current saved reply and preserves fields you omit when submitting the PUT request. Empty fields are rejected; clearing an individual channel is not supported. Avoid simultaneous edits to the same saved reply, since the read and write are separate requests. Use `template --format json` or `template --format md` to inspect both email and chat content. With `templates --include-chat`, table output adds a chat preview column when chat previews are returned.

Create may succeed without returning an ID; its receipt then has `templateID: null`. List templates to find the new reply instead of creating it again. After a timeout or server error on any write, inspect the inbox's saved replies before retrying. These commands have offline test coverage; live saved-reply writes have not been verified.

Direct `--template` use already treats the saved reply as HTML, so do not combine it with `--html`. Scout does not implement Help Scout's variable engine. When drafting or sending, bodies from every source are rejected if they contain unresolved `{%...%}` markers. Export, replace variables, and submit the edited file. Help Scout documents markers such as `{%customer.firstName,fallback=there%}`.[^5]

## Library usage

```swift
import ScoutKit

let configuration = try ScoutConfiguration.load()
let client = ScoutClient(configuration: configuration)
let page = try await client.customers(email: "jane@example.com")
let conversation = try await client.show(987654)
let draft = try await client.createDraft(
    conversation: 987654,
    content: .text("Thanks for the details.", html: false)
)
```

The library never prints. `ScoutHTTPClient` accepts an injected transport, token store and clock for offline tests. `ScoutClient` owns endpoint selection, pagination and reply construction. `OutputFormatter` and `ReplyBody` are independently testable.

## Initial release limits and verification

This version supports auth, inboxes, conversation read/search/status changes, attachment download, customer read/filter, saved-reply read/create/update/delete/use, draft creation/update/publication and new reply sending. Attachment upload and editing, customer editing, new outbound conversations, local template storage, browser OAuth, general scheduling, draft deletion and multiple accounts are deferred. The original implementation plan is in [PLAN.md](PLAN.md); the draft lifecycle plan and API research are in [DRAFT-LIFECYCLE-PLAN.md](DRAFT-LIFECYCLE-PLAN.md).

Tests use fake HTTP responses and isolated configuration fixtures. **No live Help Scout API call or real message send has been used to validate this release.** First try `auth status`, `ro inboxes`, `ro list`, and `ro show` with your credentials, then `ro show ID -o DIR` on a conversation with an image attachment. Verify drafting and status preservation on an explicitly chosen test conversation before regular use. On that test conversation, try `mark pending`, `mark closed`, and `mark active`, each followed by its API ID; confirm each status with `ro show`, then restore its original status with `mark <original-status> <id>`. Test `mark spam` separately with a disposable sender, then use Help Scout’s **Unmark as Spam** action for cleanup; the update API documentation does not specify whether setting `active` also reverses sender filtering.

[^1]: [Help Scout authentication](https://developer.helpscout.com/mailbox-api/overview/authentication/)
[^2]: [Create reply thread](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/reply/)
[^3]: [Search conversations v3](https://developer.helpscout.com/mailbox-api/endpoints/conversations/search-v3/)
[^4]: [List customers v3](https://developer.helpscout.com/mailbox-api/endpoints/customers/list-v3/)
[^5]: [Help Scout variables](https://docs.helpscout.com/article/468-variables)
[^6]: [Update conversation](https://developer.helpscout.com/mailbox-api/endpoints/conversations/update/)
[^7]: [Help Scout spam filtering and retention](https://docs.helpscout.com/article/307-manage-spam-and-unwanted-email)

[^8]: [Create saved reply](https://developer.helpscout.com/mailbox-api/endpoints/inboxes/saved_Replies/saved-replies-create/)
[^9]: [Update saved reply](https://developer.helpscout.com/mailbox-api/endpoints/inboxes/saved_Replies/saved-replies-update/)
[^10]: [Delete saved reply](https://developer.helpscout.com/mailbox-api/endpoints/inboxes/saved_Replies/saved-replies-delete/)
[^11]: [Update thread](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/update/)
[^12]: [Update thread schedule](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/schedule/update/)
[^13]: [Publish thread schedule](https://developer.helpscout.com/mailbox-api/endpoints/conversations/threads/schedule/publish/)
[^14]: [Schedule a reply to send later](https://docs.helpscout.com/article/1577-schedule-a-reply-to-send-later)
[^15]: [Get attachment data](https://developer.helpscout.com/mailbox-api/endpoints/conversations/attachments/get-data/)
