# Device and OS matrix

Physical testing is required for audio claims. The simulator can validate state
and deterministic adapters but cannot prove hardware routing, interruptions,
voice quality, energy use, or Apple model installation.

Use `Scripts/run-device-validation.sh <physical-device-udid>` to capture the
automated package-test evidence and create a report scaffold. Complete the
manual scenario table in the generated report before treating a device cell
as validated. The report format is documented in
`Documentation/DeviceValidationReport.md`.

## Release matrix

Representative devices are selected by release date, not by an untracked
marketing label: “current iPhone” is the newest iPhone that supports the
release SDK; “older iPhone” is the oldest supported iPhone available to the
maintainer; “current iPad” is the newest supported iPad. Record model number,
OS version, OS build, Xcode, SDK, and route for every report.

| Dimension | Required coverage | Result |
|---|---|---|
| device | current iPhone, older supported iPhone, current iPad | record model/build |
| route | built-in, AirPods/Bluetooth HFP, wired where supported | record route and format |
| model | installed, missing, installation allowed, installation interrupted | record outcome |
| voices | compact-only, enhanced installed, premium installed, requested id missing | record selected voice and reported quality |
| permissions | first run, denied, restricted, later approved | record recovery |
| system events | call, Siri, alarm/notification, media-services reset, background, lock/unlock | record terminal behavior |
| endurance | rapid turns and 30-minute repeated use, active close, process relaunch | record leaks, heat, memory, and recovery |

## Evidence template

For each scenario record:

```text
Package/version:
Xcode/SDK:
Device and iOS build:
Locale:
Model state:
Permission state:
Audio route:
Scenario:
Expected result:
Observed result:
Latency/memory notes:
Crash or leak:
Issue/regression test:
```

An untested cell is “unknown,” not “passed.” Release notes must identify
unknowns explicitly.

## Measurement acceptance

- Every scenario has a stable ID and result `pass`, `fail`, or `unknown`.
- A pass requires no crash, no stuck operation, no duplicate terminal event,
  no stale-generation event, and balanced microphone/tap/analyzer/audio-session
  resources after cleanup.
- Latency is recorded in milliseconds as median and p95 over at least five
  synthetic repetitions where timing applies.
- Memory is recorded in MB at start and end; endurance records the delta and
  whether Instruments or MetricKit was used.
- Thermal/energy observations identify the tool and sampling interval; no
  simulator result substitutes for a device measurement.
