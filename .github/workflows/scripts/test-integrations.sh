#!/usr/bin/env bash
set -euo pipefail

# Test integration tests by building bifrost-http from source, starting it,
# and running Python and TypeScript SDK integration tests
# Usage: ./test-integrations.sh [--parallel-files]

PARALLEL_FILES=false
case "${1:-}" in
  "") ;;
  --parallel-files) PARALLEL_FILES=true ;;
  *)
    echo "Usage: $0 [--parallel-files]" >&2
    exit 2
    ;;
esac

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [--parallel-files]" >&2
  exit 2
fi

# Ceiling on concurrently running test files in --parallel-files mode.
#
# Provider quotas, not runner CPU, are the binding constraint: every test file talks
# to live provider APIs, so an unbounded fan-out over all Python and TypeScript files
# hits per-account rate limits (and intermittent CI failures) long before it exhausts
# the runner. vitest.config.ts caps the TypeScript suite at maxWorkers: 1 for exactly
# that reason; handing each file to its own Vitest process bypasses that cap, so the
# ceiling has to be reimposed here across both suites.
#
# Validated here, above the mktemp calls below, so a bad value cannot leak a temp
# directory by exiting before `trap cleanup EXIT` is installed.
TEST_MAX_PARALLEL="${INTEGRATION_TEST_MAX_PARALLEL:-4}"
case "$TEST_MAX_PARALLEL" in
  ''|*[!0-9]*|0)
    echo "❌ INTEGRATION_TEST_MAX_PARALLEL must be a positive integer, got '$TEST_MAX_PARALLEL'" >&2
    exit 2
    ;;
esac

# Get the absolute path of the script directory
if command -v readlink >/dev/null 2>&1 && readlink -f "$0" >/dev/null 2>&1; then
  SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
else
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
fi

# Repository root (3 levels up from .github/workflows/scripts)
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"

# Setup Go workspace for CI (go.work is gitignored, must be regenerated)
source "$SCRIPT_DIR/setup-go-workspace.sh"

echo "🧪 Running Integration Tests"
echo "   Repository root: $REPO_ROOT"

# Configuration
TEST_PORT="${PORT:-8080}"
TEST_HOST="${HOST:-localhost}"
BIFROST_PID=""
TEST_FAILED=0
LOG_FILE="$(mktemp /tmp/bifrost-integrations.XXXXXX.log)"
TEST_LOG_DIR="$(mktemp -d /tmp/bifrost-integration-tests.XXXXXX)"
TEST_PIDS=()
TEST_LABELS=()
TEST_LOG_FILES=()

# Cleanup function
cleanup() {
  local exit_code=$?
  echo ""
  echo "🧹 Cleaning up..."

  # Stop any test-file processes still running after cancellation or an
  # unexpected script failure. The array is emptied after the normal wait.
  #
  # A negative PID targets the whole process group, not just the subshell that
  # launch_test_file backgrounded. That distinction matters: the recorded PID's
  # children are the uv/pytest/npm/vitest processes actually placing live provider
  # calls and writing logs, and signalling the subshell alone leaves them running
  # past cancellation. run_test_files_in_parallel enables monitor mode so each job
  # leads its own group and this reaches the whole tree; the bare-PID fallback
  # covers any caller that records a PID without that.
  for test_pid in "${TEST_PIDS[@]}"; do
    if [ -n "$test_pid" ]; then
      kill -- -"$test_pid" 2>/dev/null || kill "$test_pid" 2>/dev/null || true
    fi
  done
  for test_pid in "${TEST_PIDS[@]}"; do
    if [ -n "$test_pid" ]; then
      wait "$test_pid" 2>/dev/null || true
    fi
  done
  
  # Kill Bifrost server if running
  if [ -n "${BIFROST_PID:-}" ]; then
    echo "   Stopping Bifrost server (PID: $BIFROST_PID)..."
    kill "$BIFROST_PID" 2>/dev/null || true
    wait "$BIFROST_PID" 2>/dev/null || true
  fi

  if [ -n "${MCP_SERVER_PID:-}" ]; then
    echo "   Stopping MCP test server (PID: $MCP_SERVER_PID)..."
    kill "$MCP_SERVER_PID" 2>/dev/null || true
    wait "$MCP_SERVER_PID" 2>/dev/null || true
  fi

  # :- guards both: cleanup is defined before either variable is assigned.
  rm -f "${LOG_FILE:-}" "${MCP_SERVER_LOG_FILE:-}" 2>/dev/null || true
  if [ -n "${TEST_LOG_DIR:-}" ] && [ -d "$TEST_LOG_DIR" ]; then
    # rm -rf, not rm -f *.log: the directory also holds the .status markers
    # wait_for_test_slot counts, and rmdir would fail with those left behind.
    rm -rf "$TEST_LOG_DIR" 2>/dev/null || true
  fi

  exit $exit_code
}
trap cleanup EXIT

# Step 1: Obtain the bifrost-http binary
echo ""
cd "$REPO_ROOT"

# CI's build-gateway job supplies the binary as an artifact; only build it here
# when running locally (or if CI ever drops that job).
#
# The local build calls `go build` directly rather than `make build`: the
# Makefile passes GOWORK=off unless LOCAL is set, which discards the workspace
# setup-go-workspace.sh just wrote and sends the transport to the module proxy
# for core/framework/plugins. That resolves published versions, so any change
# spanning transports and an unreleased framework fails to compile here while
# building fine on a developer machine.
if [ "${SKIP_GATEWAY_BUILD:-0}" = "1" ]; then
  if [ ! -x "$REPO_ROOT/tmp/bifrost-http" ]; then
    echo "❌ SKIP_GATEWAY_BUILD=1 but no executable binary at $REPO_ROOT/tmp/bifrost-http" >&2
    exit 1
  fi
  echo "⏭️  Using prebuilt bifrost-http binary at $REPO_ROOT/tmp/bifrost-http"
else
  echo "🔨 Building UI + bifrost-http binary..."
  mkdir -p "$REPO_ROOT/tmp"
  # `make build`, not a bare `go build`: the Makefile target carries the build contract
  # (CGO_ENABLED=1, the sqlite_static tag, version ldflags, GOOS/GOARCH resolution, and
  # Linux static linking). Reproducing it here by hand means the integration suite can
  # certify a binary that differs from the artifact CI actually ships.
  #
  # LOCAL=1 keeps the go.work this script's caller just wrote. Without it the target sets
  # GOWORK=off and resolves core/framework/plugins from the module proxy, which fails to
  # build any change that spans transports and an unreleased framework - the same reason
  # the SKIP_GATEWAY_BUILD branch above exists.
  (cd "$REPO_ROOT" && make LOCAL=1 build)
fi

if [ ! -f "$REPO_ROOT/tmp/bifrost-http" ]; then
  echo "❌ Error: bifrost-http binary not found at $REPO_ROOT/tmp/bifrost-http"
  exit 1
fi

echo "✅ Build complete: $REPO_ROOT/tmp/bifrost-http"

# Step 1b: Start the local MCP fixture backing config.json's sse_mcp client.
#
# That client used to point at a hosted Composio endpoint via MCP_SSE_URL and
# friends. When the endpoint was decommissioned the config kept referencing it,
# so the gateway spent its startup retrying a dead host. examples/mcps/remote-test-server
# serves the same MCP protocol over SSE on 3012 with no auth, which is all the
# sse_mcp client needs - and it costs no secret and no egress allowlist entry.
#
# Non-fatal if missing: an unreachable MCP client makes the gateway log and move
# on, exactly as it did with the dead remote, and none of the provider
# integration tests assert on MCP.
MCP_TEST_SERVER="$REPO_ROOT/examples/mcps/remote-test-server/bin/remote-test-server"
if [ -x "$MCP_TEST_SERVER" ]; then
  echo ""
  echo "🔌 Starting local MCP test server (SSE on 3012)..."
  # mktemp rather than a fixed /tmp path, matching LOG_FILE above: a predictable name in a
  # world-writable directory can be pre-created as a symlink by another local process, and this
  # redirect would then truncate whatever it points at with the runner's permissions.
  if ! MCP_SERVER_LOG_FILE="$(mktemp /tmp/mcp-test-server.XXXXXX.log)"; then
    echo "❌ Failed to create MCP test server log file" >&2
    exit 1
  fi
  MCP_HTTP_PORT=3011 MCP_SSE_PORT=3012 "$MCP_TEST_SERVER" > "$MCP_SERVER_LOG_FILE" 2>&1 &
  MCP_SERVER_PID=$!
  for _ in $(seq 1 40); do
    if nc -z localhost 3012 2>/dev/null; then break; fi
    sleep 0.25
  done
  if nc -z localhost 3012 2>/dev/null; then
    echo "   ✅ MCP test server ready (PID: $MCP_SERVER_PID)"
  else
    echo "   ⚠️  MCP test server did not come up; sse_mcp client will be unreachable"
  fi
else
  echo "⚠️  MCP test server not built at $MCP_TEST_SERVER; sse_mcp client will be unreachable"
fi

# Step 2: Start Bifrost server with Python integration test config
echo ""
echo "🚀 Starting Bifrost server..."
echo "   Config: tests/integrations/python/config.json"
echo "   Host: $TEST_HOST"
echo "   Port: $TEST_PORT"

# Start server in background with Python config directory
"$REPO_ROOT/tmp/bifrost-http" \
  -host "$TEST_HOST" \
  -port "$TEST_PORT" \
  -log-style json \
  -log-level info \
  -app-dir "$REPO_ROOT/tests/integrations/python" \
  > "$LOG_FILE" 2>&1 &

BIFROST_PID=$!
echo "   Started with PID: $BIFROST_PID"


# The gateway's own stdout/stderr goes to $LOG_FILE, which cleanup() deletes on exit. A
# bootstrap failure (bad config path, unopenable store, port in use) is therefore invisible
# in CI - the job reports only "process died unexpectedly". Dump the tail before exiting.
dump_server_log() {
  echo ""
  echo "----- last 50 lines of bifrost server log ($LOG_FILE) -----"
  tail -n 50 "$LOG_FILE" 2>/dev/null || echo "   (log file unreadable)"
  echo "-----------------------------------------------------------"
}

# Wait for server to be ready
echo "⏳ Waiting for Bifrost to be ready..."
MAX_WAIT=30
ELAPSED=0
SERVER_READY=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
  if curl --connect-timeout 10 --max-time 20 -sf "http://$TEST_HOST:$TEST_PORT/health" > /dev/null 2>&1; then
    SERVER_READY=true
    echo "✅ Bifrost is ready (took ${ELAPSED}s)"
    break
  fi
  
  # Check if server process is still running
  if ! kill -0 "$BIFROST_PID" 2>/dev/null; then
    echo "❌ Bifrost process died unexpectedly"
    dump_server_log
    exit 1
  fi
  
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if [ "$SERVER_READY" = false ]; then
  echo "❌ Bifrost failed to start within ${MAX_WAIT}s"
  dump_server_log
  exit 1
fi

# Set environment variable for tests
export BIFROST_BASE_URL="http://$TEST_HOST:$TEST_PORT"
echo "   BIFROST_BASE_URL=$BIFROST_BASE_URL"

# Step 3: Prepare and run the SDK integration suites.
PYTHON_TEST_DIR="$REPO_ROOT/tests/integrations/python"
TYPESCRIPT_TEST_DIR="$REPO_ROOT/tests/integrations/typescript"
PYTHON_TEST_COMMAND=()

install_python_dependencies() {
  echo ""
  echo "🐍 Preparing Python integration tests..."
  echo "="
  cd "$PYTHON_TEST_DIR"

  if command -v uv >/dev/null 2>&1; then
    echo "📦 Installing Python dependencies with uv..."
    uv sync --frozen --quiet
    PYTHON_TEST_COMMAND=(uv run pytest)
  else
    echo "⚠️  uv not found, trying pip..."
    if [ ! -d ".venv" ]; then
      python3 -m venv .venv
    fi
    source .venv/bin/activate
    pip install -q -e .
    PYTHON_TEST_COMMAND=(pytest)
  fi
}

install_typescript_dependencies() {
  echo ""
  echo "📘 Preparing TypeScript integration tests..."
  echo "="
  cd "$TYPESCRIPT_TEST_DIR"

  if [ ! -d "node_modules" ]; then
    echo "📦 Installing TypeScript dependencies with npm..."
    npm ci
  fi
}

run_python_tests() {
  echo ""
  echo "🏃 Running Python tests..."
  if ! (cd "$PYTHON_TEST_DIR" && "${PYTHON_TEST_COMMAND[@]}" -v --tb=short); then
    echo "⚠️  Python tests failed"
    TEST_FAILED=1
  fi
}

run_typescript_tests() {
  echo ""
  echo "🏃 Running TypeScript tests..."
  if ! (cd "$TYPESCRIPT_TEST_DIR" && npm test); then
    echo "⚠️  TypeScript tests failed"
    TEST_FAILED=1
  fi
}

launch_test_file() {
  local working_directory="$1"
  local label="$2"
  shift 2

  local index="${#TEST_PIDS[@]}"
  local log_file="$TEST_LOG_DIR/$index.log"
  local status_file="$TEST_LOG_DIR/$index.status"
  echo "   Starting $label"
  (
    cd "$working_directory"
    if "$@" > "$log_file" 2>&1; then
      test_status=0
      echo "   ✅ Finished $label"
    else
      test_status=$?
      echo "   ❌ Finished $label (exit $test_status)"
    fi
    # Written last, and only on a natural exit. wait_for_test_slot counts these
    # markers rather than probing the PIDs: bash does not reap a background child
    # until it is waited on, so a finished-but-unreaped job is a zombie that still
    # answers `kill -0` successfully and would stall the throttle forever. A job
    # killed by cleanup() leaves no marker, which is correct - by then nothing is
    # waiting on a slot.
    echo "$test_status" > "$status_file"
    exit "$test_status"
  ) &
  TEST_PIDS+=("$!")
  TEST_LABELS+=("$label")
  TEST_LOG_FILES+=("$log_file")
}

# Block until fewer than TEST_MAX_PARALLEL launched jobs are still running.
wait_for_test_slot() {
  local status_files
  while :; do
    shopt -s nullglob
    status_files=("$TEST_LOG_DIR"/*.status)
    shopt -u nullglob
    if [ $(( ${#TEST_PIDS[@]} - ${#status_files[@]} )) -lt "$TEST_MAX_PARALLEL" ]; then
      return 0
    fi
    sleep 1
  done
}

run_test_files_in_parallel() {
  local python_test_files=()
  local typescript_test_files=()
  local test_file
  local index
  local test_status

  shopt -s nullglob
  python_test_files=("$PYTHON_TEST_DIR"/tests/test_*.py)
  typescript_test_files=("$TYPESCRIPT_TEST_DIR"/tests/*.test.ts)
  shopt -u nullglob

  if [ "${#python_test_files[@]}" -eq 0 ] || [ "${#typescript_test_files[@]}" -eq 0 ]; then
    echo "❌ Expected both Python and TypeScript integration test files" >&2
    return 1
  fi

  echo ""
  echo "🏃 Running ${#python_test_files[@]} Python and ${#typescript_test_files[@]} TypeScript test files,"
  echo "   at most $TEST_MAX_PARALLEL at a time (INTEGRATION_TEST_MAX_PARALLEL)..."

  # Monitor mode for the launch-and-wait window. Without it every `&` job lands in
  # this script's own process group, and cleanup() cannot group-kill a test's
  # uv/pytest/npm/vitest descendants on cancellation. Restored below so the rest of
  # the script keeps the shell's default job-control behaviour.
  set -m

  for test_file in "${python_test_files[@]}"; do
    wait_for_test_slot
    launch_test_file \
      "$PYTHON_TEST_DIR" \
      "Python: $(basename "$test_file")" \
      "${PYTHON_TEST_COMMAND[@]}" "$test_file" -v --tb=short
  done

  for test_file in "${typescript_test_files[@]}"; do
    wait_for_test_slot
    # Each Vitest process receives exactly one file. This intentionally bypasses
    # vitest.config.ts's suite-wide maxWorkers: 1 while leaving local runs alone;
    # TEST_MAX_PARALLEL reimposes an equivalent ceiling across both suites.
    launch_test_file \
      "$TYPESCRIPT_TEST_DIR" \
      "TypeScript: $(basename "$test_file")" \
      npm test -- "$test_file"
  done

  for index in "${!TEST_PIDS[@]}"; do
    if wait "${TEST_PIDS[$index]}"; then
      test_status=0
    else
      test_status=$?
      TEST_FAILED=1
    fi
    TEST_PIDS[$index]=""

    echo ""
    echo "----- ${TEST_LABELS[$index]} -----"
    cat "${TEST_LOG_FILES[$index]}" || true
    if [ "$test_status" -eq 0 ]; then
      echo "✅ ${TEST_LABELS[$index]} passed"
    else
      echo "❌ ${TEST_LABELS[$index]} failed (exit $test_status)"
    fi
  done

  set +m
  TEST_PIDS=()
}

install_python_dependencies

if [ "$PARALLEL_FILES" = true ]; then
  # Install both dependency sets before launching every Python and TypeScript
  # file together against the shared gateway.
  install_typescript_dependencies
  if ! run_test_files_in_parallel; then
    TEST_FAILED=1
  fi
else
  # Preserve the original sequential behavior for local and reusable-workflow
  # callers unless they explicitly opt into file-level parallelism.
  run_python_tests
  install_typescript_dependencies
  run_typescript_tests
fi

# Summary
echo ""
echo "="
if [ $TEST_FAILED -eq 1 ]; then
  echo "❌ Some integration tests failed"
  exit 1
else
  echo "✅ All integration tests passed!"
fi
