# Benchmark results (generated)

This directory holds run outputs from `benchmark-controller`. Contents are gitignored except this file.

## Layout

```text
results/runs/<Environment>/<RunId>/
  phase_1.json        # per-phase telemetry snapshot + gate evaluation
  phase_2.json
  ...
  manifest.json       # overall run outcome, plan metadata, submitter
```

**`<Environment>`** groups runs by topology (e.g. `AwsArcanePerHost`). **`<RunId>`** is a timestamp (`yyyyMMdd_HHmmss`).

- **Phase files** contain the telemetry snapshot at steady-state hold, gate pass/fail result, and (when `--redis-url` is set) Redis health metrics for that phase.
- **Manifest** records overall pass/fail, the plan that was run, and the submitter identity.

Add `-S3UploadResults` to `Run-Repro-Aws-Controller.ps1` to also upload artifacts to the Terraform-created S3 bucket.
