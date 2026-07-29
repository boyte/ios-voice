# Public hardening tracker

This tracker records release-critical work that remains visible to adopters.
It deliberately excludes private device identifiers, local paths, user speech,
and internal agent coordination.

## Corrective 0.1.1 release

- [ ] Restore green clean-checkout documentation and public-API CI gates.
- [ ] Remove provider-localized text from public error values.
- [ ] Make the tagged-release workflow support the first semantic tag without
      weakening compatibility checks for later tags.
- [ ] Run and retain the hosted simulator, benchmark, and memory CI evidence.
- [ ] Publish `v0.1.1` only after its candidate commit is green.

## Device qualification remains separate

Physical iPhone/iPad validation remains required for routes, interruptions,
external audio, model and voice availability, endurance, and relaunch. See
[Documentation/DeviceMatrix.md](Documentation/DeviceMatrix.md) and
[Documentation/DeviceValidationReport.md](Documentation/DeviceValidationReport.md).
