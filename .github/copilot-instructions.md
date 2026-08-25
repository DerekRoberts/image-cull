# Image-Cull AI Instructions

When writing code or generating scripts for this repository, you must adhere to the following architectural and security constraints:

## Container Networking
- **NEVER use `--network host` for background daemon containers** (like Ollama). 
- This project natively supports rootless Podman. In rootless environments (via slirp4netns/pasta), `--network host` does not share the host's loopback interface, causing `127.0.0.1` binds to become unreachable from the host.
- **ALWAYS use explicit port publishing** (e.g., `-p 127.0.0.1:11434:11434`) and configure internal services to bind to `0.0.0.0` so they are accessible to the host regardless of the runtime environment.

## Path Security
- **NEVER use pure lexical checks** (like `Path.relative_to` or `Path.is_relative_to`) on un-normalized paths originating from untrusted input (like a user-edited JSON report).
- **ALWAYS call `.resolve()`** on both the source and the target directory before checking containment. Un-resolved paths can contain `../` sequences that bypass lexical guards and cause directory traversal vulnerabilities.
- **Catch `ValueError`**: `Path.relative_to()` will raise `ValueError` if the path escapes. Handle it gracefully; do not let it crash the batch processing loop.

## Testing
- **No Live Ollama in CI**: The GitHub Actions CI runner does not have a live Ollama instance. Any self-check or test that touches `run_cull` must explicitly mock `ensure_model` using `patch.object(sys.modules[__name__], "ensure_model")`.
- **Suppress Output**: Wrap functional test calls in `contextlib.redirect_stdout` and `redirect_stderr` to prevent log pollution during `--self-check`.
