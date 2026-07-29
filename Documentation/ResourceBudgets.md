# Resource budget contract

This is the normative limit table for the host-ready API. Limits are counted
in UTF-16 code units where text is involved, because that is the unit used by
Apple synthesis callbacks and by the public transcript/progress ranges. A
limit breach has a typed result; no API silently truncates host text.

The implementation is not complete until every row is enforced by a pure or
deterministic test. The current checkout predates several aggregate controls;
those rows are deliberately marked as implementation work rather than treated
as existing behavior.

| Resource | Default / valid value | On limit | Owner | Measurement and required test | Status |
| --- | --- | --- | --- | --- | --- |
| One transcript snapshot or final | 1,048,576 UTF-16; fixed | fail the session with `textTooLong` and cleanup | recognition coordinator | boundary at max/max+1; UTF-16 emoji test | implemented locally |
| One immediate/queued speech request | 1,048,576 UTF-16; fixed | reject before an identity is accepted with `textTooLong` | facade/queue admission | boundary at max/max+1; no queue mutation | implemented locally |
| One synthesizer utterance | default 4,000; 128...32,000 | reject invalid configuration; split valid long text only at safe boundaries | Apple output | validation plus Unicode chunk reconstruction | implemented locally |
| Pending attempt count | default 32; 1...128 | apply configured overflow policy, with one terminal result for any evicted attempt | queue engine | capacity and every overflow-policy test | implemented locally |
| Replay item count | default 64; 0...256 | evict oldest replayable item; later replay reports `itemUnavailable` | queue engine | deterministic eviction/replay test | implemented locally |
| Aggregate pending text | default 1,048,576; 8,192...4,194,304 | reject admission with `queueTextBudgetExceeded`; do not evict accepted pending work merely to admit new text | queue engine | overflow-safe sum, exact boundary, replacement transaction, mixed UTF-16 test | implemented locally |
| Aggregate replay-history text | default 2,097,152; 8,192...8,388,608 | evict oldest accepted immutable items until both count and text budgets hold | queue engine | count/text conflict and replay-unavailable test | implemented locally |
| Recognition final-result cache | 16 terminal sessions or 2,097,152 UTF-16 total, whichever occurs first | evict least-recently-finished result; later finish uses stale-ID failure | recognition coordinator | expiry/racing-finish test; no retained text after close | E4 PTT-03 |
| Speech terminal-result cache | 256 results; metadata only | evict oldest result after waiters have been resumed | queue coordinator | waiter-after-terminal and bounded-cache test | E5 QUE-04 |
| Event observers | 8 process-wide canonical subscribers | reject only the new observer with `eventSubscriberLimitReached` | event delivery | two-subscriber isolation and ninth-admission test | implemented locally |
| Durable events per observer | 32 | terminate only the slow observer with `eventDeliveryOverflow` | event delivery | overflow cursor and healthy-observer test | implemented locally |
| Advisory transcript preview/progress | one coalesced current value per active session/playback; no replay history | replace prior advisory value; terminal events remain durable | event delivery | slow-consumer bounded-memory/range-order test | E6/E7 |
| Cleanup observation | 2 seconds per bounded cleanup join; fixed | enter typed blocked recovery, retain no new work admission | coordinator | non-cooperative provider and retry-close test | implemented locally |
| Recognition duration | 120 seconds default; finite 1...600 seconds; `nil` unlimited | ordinary finalization with `durationLimitReached`, unless cleanup fails | recognition coordinator | clock starts at listening; boundary/race/cache tests | E4 PTT-03 |

The maximum retained text once E5 and E4 land is bounded by the sum of the
largest permitted simultaneously retained text stores: 1,048,576 current
transcript + 4,194,304 pending queue + 8,388,608 replay history + 2,097,152
session final cache = **15,728,640 UTF-16 code units** (about 30 MiB for the
code units alone, before Swift/String overhead). The default bound is
1,048,576 + 1,048,576 + 2,097,152 + 2,097,152 = **6,291,456 UTF-16 code
units**. Implementations must use overflow-reporting addition and must not
allocate based on an unchecked sum.

The figures are memory-safety limits, not a promise of a process resident-set
size. Release performance budgets are separate: deterministic tests must show
balanced resources; simulator campaigns must report rather than hide memory
growth; and device validation must measure repeated turns, 30-minute endurance,
thermal state, and external route behavior. See [Benchmarks.md](Benchmarks.md)
and [LibraryImprovementPlan.md](LibraryImprovementPlan.md).
