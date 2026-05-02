//! `benchmark-controller` binary entry point.
//!
//! Wires together the controller's components: load plan → connect to
//! orchestrator → start results writer → run scheduler → emit manifest.
//!
//! Real wiring lands as the component PRs land (#77 through #81). For now
//! the binary just prints help / exits — the crate is published so the
//! rest of the toolchain can depend on it.

fn main() {
    eprintln!(
        "benchmark-controller: scaffold only. Component implementations land in \
         arcane-scaling-benchmarks issues #77 (TOML schema), #78 (scheduler), \
         #79 (gate), #80 (results writer), #81 (harness shrink)."
    );
}
