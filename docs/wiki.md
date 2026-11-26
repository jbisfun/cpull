# Wiki (`src/wiki`)

cpull builds the workspace wiki: one static site from every repo of a [pull workspace](workspace.md), the Zig port of the Rust `wiki` tool. Its data (wiki.toml, templates, pages, client assets, translations) stays in the workspace's `wiki` repo. Output and build state live in `$ROOT/.pull/cpull/wiki/` (`dist/`, `build/`; `$CPULL_WIKI_DIR` moves them).

* `cpull wiki build [--force]` builds `dist/`, regenerating only what changed (git object ids).
* `cpull wiki publish` builds, mirrors `dist/` into `$ROOT/jbisfun.github.io` (or `$WIKI_PUBLISH_DIR`) and stages it. The pull precommit hook runs it.
* The workspace server (`pull cpull open --web-listen ADDR`) serves the wiki live at `/wiki/`, rebuilding at most every few seconds as pages are requested.
* Pages are machine-translated only with `WIKI_TRANSLATE=1`; otherwise the cached translations in the wiki repo are used.

## Code highlighting

Fenced code is highlighted at build time with tree-sitter and the grammars' own `highlights.scm` queries (bash, C, CSS, diff, HTML, INI, JavaScript, JSON, Lua, Make, Markdown, Objective-C, Python, Ruby, Rust, Swift, TOML, TSX, TypeScript, XML, YAML, Zig). Other languages are plain text.

The output looks like the Rust wiki's, which used syntect: every token is a span of TextMate scope classes (`hl-keyword hl-control hl-rust`) inside the language's scope (`hl-source hl-rust`), and the stylesheet ends with syntect's own CSS for those classes (`src/highlight/highlight.css` in the [theme](https://github.com/jbisfun/theme) package, InspiredGitHub light and base16-ocean dark). Its `highlight` module maps each tree-sitter capture to the scope syntect gave the same token, with per-language rules that can look at the node's kind, its parent and its text (a function name in a call is a call, a TOML table header isn't a key, bash builtins are `support.function`), and puts syntect's `punctuation.definition.string` around string quotes. One deliberate difference: base16-ocean's dark comment colour (`#65737e`, 3.0:1 on the code well) is below WCAG AA, so the wiki's style.css and cpull.css lighten it to `#8a97a3` (4.9:1) in dark mode; InspiredGitHub's light colours are kept as they are. Over every code block of the last Rust-built site, 97% of the characters get the same colour; the rest are languages without a grammar here (R, PowerShell, Vue, ...), syntect's own parse errors, and SQL that syntect highlighted inside Python strings.

## Client assets

esbuild bundles and minifies `assets/main.js` (Bootstrap, clipboard.js) and `assets/style.css` (with Bootstrap's CSS) into `dist/_assets`. It is a devDependency of the wiki repo, so `pnpm install` there, which the npm packages and JSDoc already need, also brings the bundler at the version pnpm-lock.yaml pins. Nothing has to be on the PATH of what runs the build. `$WIKI_ESBUILD` points at another esbuild binary.

## The wiki and the forge

When the workspace server serves the wiki, each page it sends gets `<meta name="cpull-wiki" content="/wiki/_cpull">`. The wiki's `assets/forge.js` (bundled into every page) only runs when that tag is there, so the published site never shows or links any of this:

* Every page of a repo shows a link to the repo in cpull, its open issues and reports, and the status of its CI projects (`/ci/api/projects`). The home page's repo cards show their open issues.
* A doc page lists the open reports anchored to its file. It highlights the reported lines, with a flag in the margin that links to each issue.
* The right-click report menu files the report straight away. Select text, right-click, add a note and press "File report". A toast links to the new issue. On the static site the menu copies the `pull cpull report ...` command instead.

The API behind it (`src/wiki/forge.zig`):

* `GET /wiki/_cpull/page?repo=R&file=F`: R's cpull urls, open issue and report counts, and the open reports anchored to F.
* `GET /wiki/_cpull/repos`: the same counts for every repo.
* `POST /wiki/_cpull/report`: a JSON body `{repo, file, line, quote?, note?, title?}` files a report with source `wiki`, as `cpull report` does. It returns `{id, title, repo, file, line, url}`. The request must be same-origin and `application/json`.
