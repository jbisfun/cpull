Reports are issues pinned to a line of code: a note about one line, the way a code review comment is. They replace [radar](https://github.com/jbisfun/radar), which kept them in its own database. Now each report is an ordinary issue in the repo it points at. It syncs, merges and shows up like any other issue, and carries the `report` label.

Filing one

* `cpull report REPO FILE LINE` files a report in a [pull workspace](workspace.md). REPO is a pullfile repo, or `.` for the workspace's events repo. FILE is relative to the repo. The line's text is read from the file:

  ```
  cpull report pull src/main.zig 42 -q "unwrap()" -n "panics on an empty pullfile"
  ```

* `-n`/`--note` becomes the issue description, and its first line is the title unless `--title` gives one. `-q`/`--quote` keeps the selected text when it's narrower than the line. `--source` says where it came from (`cli` by default; ycode, the wiki and MCP set their own). `--labels` adds labels to `report`.

* Through pull, use `pull cpull report ...`. pull first sets each repo's identity, as it does for `pull cpull open`, and then runs `cpull report`.

* `cpull report list [--all] [--json]` lists open reports across every repo, oldest first. `--all` adds closed ones. `show`, `close` and `reopen` take a report id, and a unique prefix will do.

The anchor

* A report is an issue event with an extra `anchor` object:

  ```
  {"id":"5f1c...","kind":"issue","data":{"title":"panics on an empty pullfile","description":"...","labels":"report","status":"open","anchor":{"file":"src/main.zig","line":42,"line_text":"    const pf = load().unwrap();","quote":"unwrap()","commit":"9b93...","source":"cli"}}}
  ```

* `anchor` is only written when there is one, so other issues serialize exactly as before. cpull builds without anchors ignore the field. `quote`, `commit` and `source` are left out when unset.

* `commit` is HEAD when the report was filed, recorded only when HEAD's copy of the file has the same text on that line. A line filed against uncommitted work has no commit.

In the web UI

* An anchored issue's page shows the code around the line. It is read at the anchor's commit, or else from the current file. In the current file, the line is found again by its text if it has moved, and the page says if the text has changed.

* The files view flags the lines that open reports point at and lists those reports above the file. Each flag links to its issue. Patch revision files and diffs (commit and patch diffs) flag them too: a diff flags the kept or added line that holds the report's text nearest its line number.

* In local and workspace mode, clicking a line number in the files view opens a small form under the line (the text selected on the page becomes the quote). Without javascript, the same form sits folded in the file's header and takes a line number. It posts to `/<repo>/report`, which files the report at the commit the page shows, with `source` `web`, and opens the new issue.

Migrating radar

* `cpull report migrate FILE` files every report in `radar list --all --json` output (`-` reads stdin). Each report keeps its status, note, quote, source and filing time, and gets the `radar` label. The commit is found by walking the repo's history back to the filing time. Issue ids come from radar's report numbers, so running the migration again skips reports it has already filed:

  ```
  radar list --all --json > radar.json
  pull cpull report migrate radar.json
  ```
