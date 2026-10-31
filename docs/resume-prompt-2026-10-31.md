# Photo Sorter — saved resume prompt (2026-10-31)

**HALTED — saved, not resumed.** This file only prepares a future handoff. Opening or reading it does not resume implementation. Only the user explicitly pasting/invoking the prompt below resumes the scoped engineering work. Release publishing remains halted until the user explicitly resumes that phase.

- Repository: `/Users/dev/Documents/GitHub/raw_jpg_sort_photos`
- GitHub: https://github.com/ramsaijanapana/raw_jpg_sort_photos
- WIP branch: `codex/wip-local-work-2026-10-31`
- Historical checkpoint: `6963e20` (not a resume checkout target; no app-code WIP changes were pending)
- App: Photo Sorter: RAW+JPG; App Store ID `6808624854`; bundle ID `io.devara.photosorter`
- App Store state: owner-provided read-only App Store Connect GET, 2026-10-31 08:52 EDT: version `1.0`, build `1.0.0 (5)`, **Rejected**.

## Copy-ready prompt

```text
Resume scoped Photo Sorter engineering from the saved WIP branch only because I explicitly pasted this prompt. Keep release publishing halted unless I separately and explicitly resume that phase. Do not contact Apple, change App Store Connect, submit or resubmit, or interpret this prompt as release authorization.

Repository: /Users/dev/Documents/GitHub/raw_jpg_sort_photos
Remote: https://github.com/ramsaijanapana/raw_jpg_sort_photos
Branch: codex/wip-local-work-2026-10-31
Historical checkpoint (not a checkout target): 6963e20
App identity: Photo Sorter: RAW+JPG, app 6808624854, bundle io.devara.photosorter
Latest known App Store state: read-only owner check on 2026-10-31 08:52 EDT: version 1.0, build 1.0.0 (5), Rejected.

First fetch `origin/codex/wip-local-work-2026-10-31`, verify `6963e20` is an ancestor of its latest remote HEAD (`git merge-base --is-ancestor 6963e20 origin/codex/wip-local-work-2026-10-31`), and record the fetched WIP HEAD and worktree state. Treat `6963e20` only as a historical checkpoint, never as a checkout/reset target. Create a uniquely named engineering branch from the latest WIP HEAD (for example `codex/photo-sorter-resume-YYYY-MM-DD`); preserve the WIP branch and its documents unchanged. Never reset or recreate the WIP branch. Read docs/app-review-handoff-2026-10-31.md and this prompt. The authoritative current review record is https://appstoreconnect.apple.com/apps/6808624854/distribution/reviewsubmissions/details/390d5220-a2fb-4be9-9d34-03db06fdc1df. Recheck its live status and latest reviewer messages read-only before planning. The known September 15 Guideline 4.3(a) message says the binary, metadata, and/or concept is similar to other developer submissions with minor differences and asks for unique content/functionality; Apple warned of extended review. The developer requested clarification, but Apple's latest reply only said adjust and resubmit. Apple did not name a matching app or a specific copied element. Do not claim template use, code copying, or a particular comparator as fact. Do not send a message to Apple without my explicit authorization.

Then do this work in order:
1. Establish what was actually submitted in build 1.0.0 (5): inspect the source/release identity history (`git log --oneline -- app/ios app/lib`, `git show --stat 1674883`, and `git show da004d2` where available), App Store metadata/assets, and any locally available build evidence. Keep source-level observation separate from facts about the submitted binary; record missing provenance instead of guessing.
2. Audit the actual end-to-end photography workflow and its distinguishing behavior. Start with `app/lib/core/scanner.dart`, `app/lib/core/raw_preview/`, `app/lib/core/cull_session.dart`, `app/lib/core/exporter.dart`, `app/lib/state/file_operation_workflow.dart`, and the review/sort UI. Check the existing original differentiators: RAW+JPG pairing by filename stem, toggling between companion JPG and embedded RAW preview, persistent keep/skip culling with undo/resume, and exporting selected RAWs with optional JPG companions. Compare these concrete workflows and shipped assets/metadata against evidence Apple identifies if it provides any. Do not assume these descriptions alone prove uniqueness.
3. Write a concise evidence-based differentiation proposal that changes meaningful photography functionality/content and identifies affected source, assets, and store metadata. Avoid cosmetic-only edits. If Apple's feedback remains nonspecific, keep hypotheses labeled and make the product audit itself reproducible. Do not invent a matching app.
4. After the remediation is scoped, implement the agreed product changes and add/update focused tests. Relevant existing coverage includes `app/test/core/scanner_test.dart`, `app/test/core/raw_preview_extractor_test.dart`, `app/test/core/cull_session_test.dart`, `app/test/core/exporter_test.dart`, `app/test/state/cull_controller_test.dart`, and `app/test/document_provider/file_operation_workflow_test.dart` plus `file_operation_workflow_ui_test.dart`. Validate with `cd app && flutter analyze && flutter test`; also manually verify on a supported device using rights-cleared camera RAW+JPG sample files: pair detection, preview switching, culling persistence/undo, and exported file contents. Save commands/results and before/after evidence in the repo without claiming unrun checks.
5. Report the proposed and completed changes, evidence, remaining uncertainty, and validation results. Do not archive, upload, change listing metadata in App Store Connect, or resubmit. Those release actions require a separate explicit user instruction.

At every step preserve unrelated user work and avoid exposing credentials. Keep the product focused on a demonstrably distinct RAW/JPG photography workflow; do not make unsupported claims about why Apple rejected it.
```
