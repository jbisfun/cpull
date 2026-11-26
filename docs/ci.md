# CI (`src/ci`)

cpull's workspace server runs the CI for the [idl](https://github.com/jbisfun/idl) projects
of its pull workspace (every directory holding an `idlproj.yml`, up to 5 levels down). It is
a Zig port of idlci: same job queue, Jenkins-style pages, JSON API and CLI.

- **Server**: `cpull --workspace DIR --web-listen ADDR [--ci-jobs N] [--ci-watch [--ci-watch-interval S]]`.
  Pages at `/ci` (dashboard, `/ci/projects/<path>`, `/ci/jobs`, `/ci/jobs/<id>` with a live
  console). `--ci-watch` queues `build` and `test` when a project's (or a target dir's) git HEAD moves.
- **API** (idlci's, under `/ci`): `GET /ci/api/health`, `GET /ci/api/projects[/<path>]`,
  `GET|POST /ci/api/jobs`, `GET /ci/api/jobs/<id>`, `POST /ci/api/jobs/<id>/cancel|retry[?by=]`,
  `GET /ci/api/jobs/<id>/log?offset=|tail=`, `GET /ci/api/jobs/<id>/events` (server-sent events).
- **CLI**: `cpull ci queue|jobs|log|cancel|retry|patch|stack` (`cpull ci --help`).
- **Forge integration** ([integrate.md](integrate.md)): CI balls on the forge pages, CI for
  patches and stacks in work trees under `.pull/cpull/ci/work/`, the `cpull.require_ci` merge
  gate, `ci` issues for failing default-branch jobs, and `fixes #id` commits closing issues.
- **MCP**: pull's `ci_*` tools (`pull mcp`).

State lives in `$ROOT/.pull/cpull/ci/` (`ci.db` with idlci's schema, `logs/<id>.log`,
`serve.lock`); the server writes its address to `$ROOT/.pull/cpull/serve.addr`. On first start an
existing `.pull/idlci/idlci.db` is copied in, so the job history carries over. Only the server
holding `serve.lock` runs jobs; another one (e.g. a TUI on the same workspace) only queues and shows
them. Jobs run `idl` (`$CPULL_IDL`, `$IDLCI_IDL`, `idl` on PATH or `~/.local/bin/idl`) in their own
process group with `PULL_ROOT` set; cancel SIGTERMs the group, then SIGKILLs it after 5s. Jobs a
previous server left running are marked failed on start and their process groups killed. On
SIGTERM/SIGINT/SIGHUP the server cancels its running jobs (process groups SIGTERMed, SIGKILLed
after 5s) before it exits. Only the server running the jobs writes `serve.addr`.
