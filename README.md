# Hooking into the Go toolchain

Companion code for the guest post "Hooking into the Go Toolchain". Every code
and output block in the post comes from this repository, from `captures/` (the
recorded output of the commands below), or from the upstream sources the post
cites.

The post walks through `go build -toolexec` in small steps: a stopwatch wrapper
that times every tool call, source rewriting at `go/parser` offsets, patching the
importcfg, `//go:linkname` into the standard library, build-cache poisoning and
its fix, and finally [otelc](https://github.com/open-telemetry/opentelemetry-go-compile-instrumentation)
(OpenTelemetry Go compile-time instrumentation).

The toy wrappers are teaching code, not tools to depend on. For real
compile-time instrumentation, use otelc.

## Prerequisites

- Go 1.25 or newer on `PATH` (the module says `go 1.25`; otelc v1.1.0 needs
  1.25 too). The captures were recorded with Go 1.27.1. `make check-go126`
  repeats steps 2 to 6 with Go 1.26.8, which it expects at
  `~/sdk/go1.26.8/bin/go`; override with `GO126=/path/to/go`.
- macOS or Linux. The captures were recorded on `Darwin arm64`; `step0` uses
  BSD `/usr/bin/time`.
- `jq`, `curl` and `python3` for `step7`.
- `shellcheck` and `shfmt` for `make check`.
- Network access the first time, to fetch otelc and its dependencies.

Nothing is installed globally. Tools go to `.bin/`, every target builds with a
fresh `GOCACHE` under `.cache/`, and `GOFLAGS` is cleared. The one exception is
the Go module cache (`GOMODCACHE`, by default `~/go/pkg/mod`): `make
otelc-install`, `make step7` and `make stats` download otelc and its
dependencies into it.

## Layout

| Path | What it is |
| --- | --- |
| `app/`, `greet/`, `other/` | The small program for steps 0 to 6. `greet` is shared by `app` and `other`. |
| `hooks/` | `hooks.OnReadFile`, the linkname target of step 5. |
| `cmd/stopwatch/` | Step 2: a `-toolexec` wrapper that logs one line per tool call. |
| `cmd/toyhook/` | Steps 3 to 6: a wrapper that rewrites source, patches importcfg and marks `-V=full`. |
| `hello/` | HTTP server for step 7 (its own module), with `log.otelc.yml`. |
| `scripts/` | One shell script per step, plus `lib.sh`. |
| `captures/` | Recorded output. `captures/go1.26/` holds the Go 1.26.8 run. |
| `diagrams/` | Mermaid sources `D1.mmd`, `D2.mmd`, `D3.mmd`. |

## Targets

`make help` lists them. One line each:

- `make tools`: build `cmd/stopwatch` and `cmd/toyhook` into `.bin/`.
- `make otelc-install`: install otelc v1.1.0 into `.bin/`.
- `make step0`: `go build -a -toolexec=/usr/bin/time ./app`.
- `make step0-replay`: golang/go#27628. A later plain `go build` replays the cached stderr of the `-toolexec=/usr/bin/time` build.
- `make step1`: `go build -a -x -work ./app`, with the importcfg and `# internal` lines.
- `make step2`: the stopwatch: counts, slowest packages, `-V=full` probes, warm build, the two stdout bugs.
- `make step3`: `toyhook` inserts a statement into every `//demo:log` function.
- `make step4-broken`: the inserted code uses `log/slog`, which the app does not import. Compile error.
- `make step4`: `toyhook` patches the compile and link importcfg.
- `make step5`: `//go:linkname` from `os.ReadFile` to `hooks.OnReadFile`.
- `make step6-poison`: a plain build of `./other` picks up code injected while building `./app`.
- `make step6-fixed`: `toyhook` marks the `-V=full` answer and `./other` stays clean.
- `make step7`: otelc builds `./hello`: three spans, matched rules, generated code, `go.mod` check.
- `make stats`: stopwatch versus `otelc --stats` on `go build -a` of `./hello`.
- `make check`: `gofmt`, `go vet`, `go test`, `go build`, `shellcheck`, `shfmt`.
- `make captures`: run everything above and regenerate `captures/`.
- `make check-go126`: `step0-replay` and steps 2 to 6 on Go 1.26.8.
- `make clean`: remove `.cache/` and `.otelc-build/`.

## Where the captures come from

Each target writes real command output to `captures/<step>-<what>.txt`. The
only edit is a path rewrite: the repository path, `GOROOT`, the home directory,
and (only in the OpenTelemetry resource attributes of `step7-spans.txt`) the
user name and the host name become `$REPO`, `$GOROOT`, `$HOME`, `$USER` and
`$HOSTNAME`. Files ending in `.exit` hold the exit status of an expected
failure. `*.trimmed.txt` files are the same output with `go: downloading` lines
removed. `captures/versions.txt` records the Go and otelc versions, `uname -sm`
and the date.

Timings are one run on one machine. Treat them as orders of magnitude.

## Credits

- The toolexec wrapper and `//demo:log` injector started as demos for talks
  at GopherCon UK 2025 and OTel Night Berlin 2026.
- Marking the `-V=full` answer to keep instrumented builds out of plain
  builds' cache entries is the technique
  [garble](https://github.com/burrowers/garble) uses, following Russ Cox's
  suggestion in [golang/go#41145](https://github.com/golang/go/issues/41145).
- [otelc](https://github.com/open-telemetry/opentelemetry-go-compile-instrumentation)
  is developed by the OpenTelemetry Go Compile-Time Instrumentation SIG.

## License

Apache-2.0. See `LICENSE`.
