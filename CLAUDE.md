# Scout conventions

Scout is a small single-account Help Scout client. See PLAN.md for scope and API sources.

- Put business logic, configuration, networking, validation and rendering in ScoutKit. Library code never prints.
- Keep the executable a thin Swift Argument Parser wrapper. Use separate draft and send commands.
- Test offline with injected HTTP transport, credentials, token store and clock. Never read real `.env` files or send real customer messages during automated checks.
- Do not log secrets or customer message bodies. Do not automatically retry uncertain writes.
- Use current documented APIs. No speculative compatibility layers or migrations.
- Run `swift test` and `swift build -c release` before final review.
- In the managed worktree environment, SwiftPM's nested sandbox fails with `sandbox_apply: Operation not permitted`; use `swift test --disable-sandbox` and `swift build --disable-sandbox -c release` there. Workspace permissions still apply.
- Keep commits unsquashed. Do not use `git -C` or change directories in commands.
