//! `benchmark-controller` binary entry point.
//!
//! Drives the swarm orchestrator through a TOML test plan:
//!   - Connects to the orchestrator's HTTP API for command submission
//!   - Subscribes to its telemetry SSE for the validity gate
//!   - Writes per-phase results + a run manifest to a local directory
//!     (and to S3 if an `--s3-bucket` is given)
//!
//! Usage:
//!   benchmark-controller \
//!     --plan ./plans/headline-13500.toml \
//!     --orchestrator-url http://10.0.1.5:8090 \
//!     --results-dir ./results \
//!     [--submitter <id>] \
//!     [--s3-bucket <name> --s3-prefix <prefix>]
//!
//! Exit code: 0 on overall Pass, 1 on overall Fail (or any error).

use benchmark_controller::results::Uploader;
use benchmark_controller::results::{NoopUploaderExt, S3Uploader};
use benchmark_controller::run::{run, RunConfig, RunOutcome};
use std::io::IsTerminal;
use std::path::PathBuf;
use std::sync::Arc;

fn print_usage() {
    eprintln!(
        "usage: benchmark-controller \\
        --plan <plan.toml> \\
        --orchestrator-url <http://host:port> \\
        --results-dir <dir> \\
        [--submitter <id>] \\
        [--s3-bucket <name> --s3-prefix <prefix>] \\
        [--dashboard auto|on|off]   (default: auto — on iff stdout is a TTY) \\
        [--redis-url redis://host:6379]  (enables Redis health monitoring)"
    );
}

#[tokio::main]
async fn main() {
    let mut plan: Option<PathBuf> = None;
    let mut url: Option<String> = None;
    let mut results_dir: Option<PathBuf> = None;
    let mut submitter: String = format!("benchmark-controller-{}", std::process::id());
    let mut s3_bucket: Option<String> = None;
    let mut s3_prefix: Option<String> = None;
    let mut dashboard_arg: Option<String> = None;
    let mut redis_url: Option<String> = None;

    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--plan" => {
                i += 1;
                plan = Some(PathBuf::from(&args[i]));
            }
            "--orchestrator-url" => {
                i += 1;
                url = Some(args[i].clone());
            }
            "--results-dir" => {
                i += 1;
                results_dir = Some(PathBuf::from(&args[i]));
            }
            "--submitter" => {
                i += 1;
                submitter = args[i].clone();
            }
            "--s3-bucket" => {
                i += 1;
                s3_bucket = Some(args[i].clone());
            }
            "--s3-prefix" => {
                i += 1;
                s3_prefix = Some(args[i].clone());
            }
            "--dashboard" => {
                i += 1;
                dashboard_arg = Some(args[i].clone());
            }
            "--redis-url" => {
                i += 1;
                redis_url = Some(args[i].clone());
            }
            "-h" | "--help" => {
                print_usage();
                std::process::exit(0);
            }
            _ => {}
        }
        i += 1;
    }

    // Default: render the dashboard iff stdout is an actual terminal.
    // Override with --dashboard on|off; --dashboard auto re-applies the
    // TTY autodetect explicitly. CI / file redirects fall through to off
    // automatically, so the existing one-line summary still parses.
    let enable_dashboard = match dashboard_arg.as_deref() {
        Some("on") => true,
        Some("off") => false,
        Some("auto") | None => std::io::stdout().is_terminal(),
        Some(other) => {
            eprintln!("--dashboard expects auto|on|off, got {:?}", other);
            std::process::exit(2);
        }
    };

    let cfg = match (plan, url, results_dir) {
        (Some(plan), Some(url), Some(rd)) => RunConfig {
            plan_path: plan,
            orchestrator_base_url: url,
            results_dir: rd,
            submitter,
            enable_dashboard,
            redis_url,
        },
        _ => {
            print_usage();
            std::process::exit(2);
        }
    };

    let uploader: Arc<dyn UploaderObj> = match s3_bucket {
        Some(bucket) => {
            let prefix = s3_prefix.unwrap_or_default();
            Arc::new(S3Uploader::new(bucket, prefix))
        }
        None => Arc::new(NoopUploaderExt),
    };
    // We need an Uploader trait object; thread it into run via a shim that
    // calls the right concrete uploader.
    let outcome = run_with_uploader(cfg, uploader).await;
    match outcome {
        Ok(RunOutcome { overall, .. }) => {
            eprintln!("benchmark-controller: overall = {:?}", overall);
            if matches!(overall, benchmark_controller::results::OverallOutcome::Pass) {
                std::process::exit(0);
            } else {
                std::process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("benchmark-controller: error: {}", e);
            std::process::exit(1);
        }
    }
}

trait UploaderObj: Send + Sync {
    fn upload_box<'a>(
        &'a self,
        key: String,
        body: Vec<u8>,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), String>> + Send + 'a>>;
}

impl<U: Uploader + 'static> UploaderObj for U {
    fn upload_box<'a>(
        &'a self,
        key: String,
        body: Vec<u8>,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), String>> + Send + 'a>> {
        Box::pin(self.upload(key, body))
    }
}

struct UploaderObjAdapter(Arc<dyn UploaderObj>);
impl Uploader for UploaderObjAdapter {
    async fn upload(&self, key: String, body: Vec<u8>) -> Result<(), String> {
        self.0.upload_box(key, body).await
    }
}

async fn run_with_uploader(
    cfg: RunConfig,
    uploader: Arc<dyn UploaderObj>,
) -> Result<RunOutcome, String> {
    let adapter = Arc::new(UploaderObjAdapter(uploader));
    run(cfg, adapter).await
}
