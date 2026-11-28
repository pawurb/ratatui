#!/usr/bin/env bash
# Runs the hotpath-cloud benchmarks (see .github/workflows/hotpath-benchmark.yml).
#
# Each scenario is one Criterion benchmark id from `ratatui/benches/main`, run a fixed number of
# times natively (timing and allocations) and then under Callgrind (instruction counts), which
# merges both runs into `<out_dir>/<scenario>.json`. Both runs use the same build.
#
# Usage: hotpath/run-benchmarks.sh <out_dir> [--upload]
#
# With `--upload`, the Callgrind run of every scenario uploads its merged report to hotpath.rs
# (needs the OIDC token of a trusted GitHub Actions job). Without it, the reports are only written.
#
# Requires Linux x86_64 with Valgrind. Run it from the repository root.
set -euo pipefail

out_dir="${1:?usage: hotpath/run-benchmarks.sh <out_dir> [--upload]}"
upload="${2:-}"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

# The relay workflow lists the same scenario names; keep both in sync.
# Only deterministic benchmarks are listed: `paragraph`, `table`, `list`, `barchart`, `sparkline`
# and `buffer/with_lines` build their inputs from unseeded random data, and the layout solver
# behind `constraints` allocates a different amount on every run.
#
# scenario name | Criterion benchmark id | iterations
scenarios=(
  "canvas-circle-render|canvas/circle/render/braille/8|20000"
  "chart-line-render|chart/render/Line/1000|2000"
  "stored-text-clone-render-end|stored_text/clone_render_end/10000x5|50"
  "text-render|text/render/200x50|3000"
  "block-render|block/render_all_feature/200x50|10000"
)

bench_args=(
  -p ratatui --profile hotpath --bench main
  --features "hotpath-alloc,hotpath-cloud,hotpath-callgrind"
)

export HOTPATH_OUTPUT_FORMAT=json

cargo bench -q "${bench_args[@]}" --no-run

native_dir="$(mktemp -d)"
trap 'rm -rf -- "$native_dir"' EXIT

for scenario in "${scenarios[@]}"; do
  IFS='|' read -r name id iterations <<<"$scenario"
  echo "::group::$name ($id, $iterations iterations)"

  # Native run: timing and allocations.
  HOTPATH_BENCHMARK="$name" HOTPATH_CRITERION_ITERATIONS="$iterations" \
    HOTPATH_OUTPUT_PATH="$native_dir/$name.json" \
    cargo bench -q "${bench_args[@]}" -- --test --exact "$id"

  # Callgrind run of the same build, merging the native report. Only this run uploads.
  upload_env=()
  if [ "$upload" = "--upload" ]; then
    upload_env=(
      HOTPATH_UPLOAD=fail-on-error
      HOTPATH_UPLOAD_RESPONSE_PATH="$out_dir/$name.upload.json"
    )
  fi
  callgrind_out="$native_dir/callgrind.$name.out.%p"
  env ${upload_env[@]+"${upload_env[@]}"} \
    HOTPATH_BENCHMARK="$name" HOTPATH_CRITERION_ITERATIONS="$iterations" \
    HOTPATH_OUTPUT_PATH="$out_dir/$name.json" \
    HOTPATH_MERGE_REPORT="$native_dir/$name.json" \
    HOTPATH_CALLGRIND_OUT_FILE="$callgrind_out" \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUNNER="valgrind -q --tool=callgrind --instr-atstart=no --callgrind-out-file=$callgrind_out" \
    cargo bench -q "${bench_args[@]}" -- --test --exact "$id"

  if [ "$upload" = "--upload" ]; then
    test -s "$out_dir/$name.upload.json"
  fi
  jq -e --arg id "$id" \
    '.meta.run == "merged" and (.functions_icount.data | length > 0) and (.functions_timing.data | length > 0) and .meta.criterion.benchmark == $id' \
    "$out_dir/$name.json" >/dev/null
  echo "::endgroup::"
done
