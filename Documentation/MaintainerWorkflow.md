# Maintainer workflow

AppLocalVoice is maintained as a small reliability library. Every change must
make the one-line promise more dependable: convert speech to text and text to
speech on-device with predictable audio lifecycle management.

## Change classification

- **API:** public symbols, actor isolation, errors, events, or compatibility.
- **Lifecycle:** permissions, audio session, engine, analyzer, synthesizer,
  interruption, route, cancellation, or teardown.
- **Apple behavior:** OS/device-dependent behavior requiring physical evidence.
- **Test infrastructure:** fakes, fault injection, fuzzing, stress, benchmark,
  or leak detection.
- **Documentation/release:** contracts, examples, CI, changelog, or reports.

Every issue should have one primary classification and one owner. Do not combine
provider integrations, chat features, or unrelated UI work with core lifecycle
changes.

## Definition of done

Before merge:

1. the behavior is stated in the compatibility or state-machine documentation;
2. a deterministic regression test exists, or the PR explains why it requires a
   physical device;
3. public API changes have DocC coverage and a changelog entry;
4. privacy review confirms no speech content or credentials are logged;
5. the fix is recorded in the [regression ledger](RegressionLedger.md);
6. package tests and the relevant CI documentation checks pass.

## Documentation integrity

The repository Markdown gate is offline and checks every local Markdown link,
local file target, and fragment. It also requires the public API contract,
checked-in symbol baseline, DocC landing page, and all five tutorial pages to
remain present and referenced. Run it from the repository root with:

```sh
python3 Scripts/validate-documentation.py
```

HTTP(S), mailto, and tel links are intentionally preserved and are never
fetched by this check. A missing local target or malformed local destination is
a documentation failure.

## Public API evidence and ghost-API audit

Keep human API guidance in the narrative part of
[`PublicAPI.md`](PublicAPI.md). Its `Generated API evidence` section is the one
machine-checked inventory: it contains one marker for each symbol in
`PublicAPISymbols.json`, and no duplicate marker blocks. The inventory is
generated evidence, not a promise that an audit has approved every symbol for
the product surface.

Reproduce the production-only graph and validate the baseline plus markers from
the repository root:

```sh
Scripts/emit-public-symbol-graph.sh \
  /tmp/AppLocalVoice-symbol-graphs \
  /tmp/AppLocalVoice-DerivedData
python3 Scripts/validate-public-api.py \
  --symbol-graph /tmp/AppLocalVoice-symbol-graphs/AppLocalVoice.symbols.json
python3 Scripts/validate-public-docs.py \
  --symbol-graph /tmp/AppLocalVoice-symbol-graphs/AppLocalVoice.symbols.json \
  --baseline Documentation/PublicAPISymbols.json
```

Local status for the 2026-07-12 production graph: offline Markdown validation,
the 519-symbol public API marker validation, and DocC conversion with
warnings-as-errors pass. `validate-public-docs.py` is a release gate: source
documentation coverage must also pass before a candidate can be released.

The current ghost-API audit is recorded in
[`PublicAPIReview.md`](PublicAPIReview.md). Do not change the public baseline
merely to make the inventory smaller: every canonical addition, compatibility
adapter, alias removal, and currently unreachable value must retain its
consumer path and implementation owner in that review.

Before release, attach the symbol-graph diff, DocC archive result, benchmark
summary, and device matrix. Unknown device cells remain visible in the release
notes.

## Parallel work rules

Subagents must claim a narrow file scope and report discovered follow-up work
instead of silently expanding it. One integrator reviews cross-boundary changes.
Do not overwrite unrelated changes in a shared worktree. A follow-up task is
complete only when its acceptance evidence is linked from the tracker.
