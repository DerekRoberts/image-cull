#!/usr/bin/env bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
BIN_PATH="$BIN_DIR/image-cull"

echo "==> Building container image 'image-cull:latest'..."
if command -v podman >/dev/null 2>&1; then
    CONTAINER_ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_ENGINE="docker"
else
    echo "Error: Neither podman nor docker was found on your PATH."
    exit 1
fi

$CONTAINER_ENGINE build -t image-cull:latest "$PROJECT_DIR"

echo "==> Ensuring Ollama backend image is cached..."
$CONTAINER_ENGINE pull docker.io/ollama/ollama:latest || echo "Warning: could not pre-cache Ollama image; it will be pulled on first run." >&2

echo "==> Installing executable wrapper script to $BIN_PATH..."
mkdir -p "$BIN_DIR"

cat << 'EOF' > "$BIN_PATH"
#!/usr/bin/env bash
if [ "$(id -u)" -eq 0 ]; then
    echo "Error: running image-cull as root is unsupported." >&2
    exit 1
fi
TARGET_DIR="."
FILTER_HOST_DIR=""
IS_DRY_RUN=false
ARGS=()

skip_next=false
for ((i=1; i<=$#; i++)); do
    if [ "$skip_next" = true ]; then
        skip_next=false
        continue
    fi
    arg="${!i}"
    next_index=$((i+1))
    next_arg="${!next_index}"

    if [ "$arg" == "--dry-run" ]; then
        IS_DRY_RUN=true
        ARGS+=("$arg")
    elif [ "$arg" == "--filter-dir" ]; then
        if [ -z "$next_arg" ] || [[ "$next_arg" == -* ]]; then
            echo "Error: --filter-dir requires a directory path argument." >&2
            exit 1
        fi
        FILTER_HOST_DIR="$next_arg"
        skip_next=true
    elif [[ "$arg" == --filter-dir=* ]]; then
        FILTER_HOST_DIR="${arg#*=}"
        if [ -z "$FILTER_HOST_DIR" ]; then
            echo "Error: --filter-dir requires a non-empty directory path." >&2
            exit 1
        fi
    elif [[ "$arg" != -* ]] && [ -d "$arg" ]; then
        TARGET_DIR="$arg"
    else
        ARGS+=("$arg")
    fi
done

REAL_HOST_DIR="$(realpath "$TARGET_DIR")"
MOUNTS=("-v" "$REAL_HOST_DIR:/photos:z")

CONTAINER_FLAGS=()
if [ -n "$FILTER_HOST_DIR" ]; then
    if [ "$IS_DRY_RUN" = false ]; then
        mkdir -p "$FILTER_HOST_DIR"
    fi
    if [ -d "$FILTER_HOST_DIR" ]; then
        REAL_FILTER_DIR="$(realpath "$FILTER_HOST_DIR")"
        MOUNTS+=("-v" "$REAL_FILTER_DIR:/filtered:z")
        CONTAINER_FLAGS+=("--filter-dir" "/filtered")
    fi
fi

CONTAINER_ENGINE="podman"
USER_FLAGS=("--userns=keep-id" "--user" "$(id -u):$(id -g)")
if ! command -v podman >/dev/null 2>&1; then
    CONTAINER_ENGINE="docker"
    USER_FLAGS=("--user" "$(id -u):$(id -g)")
fi

ENV_FLAGS=()
if [ -n "${OLLAMA_HOST:-}" ]; then
    ENV_FLAGS+=("-e" "OLLAMA_HOST=${OLLAMA_HOST}")
fi

SPAWNED_OLLAMA=false

cleanup() {
    if [ "$SPAWNED_OLLAMA" = true ]; then
        echo "==> Stopping Ollama backend..." >&2
        $CONTAINER_ENGINE stop image-cull-ollama >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

check_endpoint() {
    local endpoint="${1%/}"
    if command -v curl >/dev/null 2>&1; then
        curl -s -f --max-time 1 "${endpoint}/api/tags" >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys, urllib.request
endpoint = sys.argv[1].rstrip("/")
def ok(url: str) -> bool:
    try:
        urllib.request.urlopen(url, timeout=1).read(1)
        return True
    except Exception:
        return False
sys.exit(0 if ok(endpoint + "/api/tags") else 1)
' "$endpoint" >/dev/null 2>&1
    else
        return 1
    fi
}

TARGET_ENDPOINT="${OLLAMA_HOST:-http://127.0.0.1:11434}"
if [ -n "${OLLAMA_HOST:-}" ] && [[ "$TARGET_ENDPOINT" != http://* && "$TARGET_ENDPOINT" != https://* ]]; then
    TARGET_ENDPOINT="http://${TARGET_ENDPOINT}"
fi

if ! check_endpoint "$TARGET_ENDPOINT"; then
    HOST_PART="${TARGET_ENDPOINT#*://}"
    HOST_PART="${HOST_PART%%/*}"
    HOST_PART="${HOST_PART%%:*}"
    case "$HOST_PART" in
        "" | "127.0.0.1" | "localhost" | "::1" | "0.0.0.0" | "[::1]") ;;
        *)
            echo "Error: Cannot reach remote Ollama at ${TARGET_ENDPOINT}" >&2
            exit 1
            ;;
    esac

    WAS_RUNNING=false
    if [ "$($CONTAINER_ENGINE inspect -f '{{.State.Running}}' image-cull-ollama 2>/dev/null)" = "true" ]; then
        WAS_RUNNING=true
    fi

    PORT="11434"
    if [[ "$TARGET_ENDPOINT" =~ :([0-9]+)/?$ ]]; then
        PORT="${BASH_REMATCH[1]}"
    fi

    echo "==> Starting container 'image-cull-ollama'..."
    if $CONTAINER_ENGINE inspect image-cull-ollama >/dev/null 2>&1; then
        EXISTING_PORT="$($CONTAINER_ENGINE inspect -f '{{range $k, $v := .NetworkSettings.Ports}}{{(index $v 0).HostPort}}{{end}}' image-cull-ollama 2>/dev/null | head -n1 || echo \"11434\")"
        if [ -z "$EXISTING_PORT" ]; then EXISTING_PORT="11434"; fi
        if [ "$EXISTING_PORT" != "$PORT" ]; then
            if [ "$WAS_RUNNING" = true ]; then
                echo "Error: Pre-existing image-cull-ollama is bound to port ${EXISTING_PORT}." >&2
                echo "Please match OLLAMA_HOST or stop it manually." >&2
                exit 1
            fi
            $CONTAINER_ENGINE rm -f image-cull-ollama >/dev/null 2>&1 || true
            $CONTAINER_ENGINE run -d \
                --name image-cull-ollama \
                --restart=unless-stopped \
                -p "127.0.0.1:${PORT}:11434" \
                -e "OLLAMA_HOST=0.0.0.0:11434" \
                -v image-cull-ollama-models:/root/.ollama:z \
                docker.io/ollama/ollama:latest >/dev/null 2>&1 || true
        else
            $CONTAINER_ENGINE start image-cull-ollama >/dev/null 2>&1 || true
        fi
    else
        $CONTAINER_ENGINE run -d \
            --name image-cull-ollama \
            --restart=unless-stopped \
            -p "127.0.0.1:${PORT}:11434" \
            -e "OLLAMA_HOST=0.0.0.0:11434" \
            -v image-cull-ollama-models:/root/.ollama:z \
            docker.io/ollama/ollama:latest >/dev/null 2>&1 || true
    fi

    if [ "$WAS_RUNNING" = false ]; then
        SPAWNED_OLLAMA=true
    fi

    attempts=0
    ready=false
    while [ $attempts -lt 120 ]; do
        if check_endpoint "http://127.0.0.1:${PORT}"; then
            ready=true
            break
        fi
        sleep 1
        attempts=$((attempts + 1))
    done

    if [ "$ready" = false ]; then
        echo "Error: Ollama backend started but did not respond on http://127.0.0.1:${PORT} within timeout." >&2
        exit 1
    fi

    ENV_FLAGS=("-e" "OLLAMA_HOST=http://127.0.0.1:${PORT}")
fi

$CONTAINER_ENGINE run --rm --network host \
    "${USER_FLAGS[@]}" \
    "${ENV_FLAGS[@]}" \
    "${MOUNTS[@]}" \
    image-cull:latest --dir /photos --report-path-display "$REAL_HOST_DIR/cull-report.json" "${CONTAINER_FLAGS[@]}" "${ARGS[@]}"
EXIT_CODE=$?
exit $EXIT_CODE
EOF

chmod +x "$BIN_PATH"

echo ""
echo "=========================================================="
echo " Setup complete!"
echo " Executable binary installed to: $BIN_PATH"
echo "=========================================================="
echo " You can now run image-cull from anywhere using:"
echo "   image-cull ~/Downloads --filter-dir ~/Desktop/Filtered_Photos --dry-run"
echo ""
