# Contributing

## Commit convention: step-by-step commits

Commit **small, logical changes one at a time** — never bundle unrelated
changes into a single commit.

Rules:

1. **One logical change per commit.** A bug fix, a feature, a refactor, or a
   doc update each get their own commit. If you touch several areas in one
   session, split the work into separate commits.
2. **Commit after each change is implemented and verified**, before moving on
   to the next change.
3. **Write clear, imperative-mood messages** describing *what* the commit does,
   not *how* it was done. Examples:

   - `Fix critical bugs in embedded SOCKS5 server`
   - `Harden bash wrapper: PID-based cleanup, parsed config, port validation, setsid`
   - `Add README with install and usage instructions`

4. Keep each commit self-contained: it should build and run on its own
   (syntax-check / test before committing).
