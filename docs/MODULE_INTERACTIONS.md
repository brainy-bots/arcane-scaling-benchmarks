# Benchmark module interactions

This page describes how benchmark scripts are separated after modularization.

```mermaid
flowchart LR
  subgraph Entry["Entry scripts"]
    V2["scripts/benchmark/Run-Benchmark-V2.ps1"]
    Cloud["infra/aws/Run-Benchmark-Aws.ps1"]
  end

  subgraph Shared["Shared modules (scripts/common)"]
    Parse["BenchmarkParsing.psm1"]
    Scenario["BenchmarkScenario.psm1"]
    Runtime["BenchmarkRuntime.psm1"]
  end

  subgraph Outputs["Run artifacts"]
    Logs["logs/"]
    Metrics["metrics/docker_stats.csv"]
    Results["benchmark_v2_results.csv"]
  end

  V2 --> Parse
  V2 --> Scenario
  V2 --> Runtime
  Cloud --> Parse
  Cloud --> Scenario
  Cloud --> Runtime

  V2 --> Logs
  V2 --> Metrics
  V2 --> Results
```

## Responsibility summary

- `BenchmarkParsing`: parse `FINAL`/`FINAL_SPACETIMEDB` lines and evaluate pass/fail criteria.
- `BenchmarkScenario`: cluster manager topology/env-line generation helpers.
- `BenchmarkRuntime`: runtime utilities for docker stats and log container naming.
- `Run-Benchmark-V2.ps1`: orchestration flow and loop control for local benchmark runs.
- `infra/aws/Run-Benchmark-Aws.ps1`: cloud-oriented orchestration variant. Provisioning and teardown are not in PowerShell — see `infra/terraform/aws_benchmark/`.

## Test coverage map

- `tests/BenchmarkParsing.Tests.ps1` covers parser and pass/fail rules.
- `tests/BenchmarkScenario.Tests.ps1` covers scenario/env generation.
- `tests/BenchmarkRuntime.Tests.ps1` covers runtime helper behavior.
