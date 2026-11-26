# Forge x CI x issues (`src/integrate`)

In a pull workspace, cpull's forge (issues, patches, stacks), its CI (`/ci`, [ci.md](ci.md))
and its issues work together. Everything here needs the workspace server
(`pull cpull open --web-listen ADDR`), except the merge gate, which `cpull stack merge` also
applies.

## CI status everywhere

* The workspace home has a **CI** column: one ball per repo, from the latest workspace job of
  each (idl project, command) in that repo. Grey `N/A` means no idl project or no job yet.
* A repo's pages get a **CI** group in the sidebar with those jobs.
* The commit history has a **CI** column: the jobs that ran on each commit (any job whose
  recorded `head` is that commit: the watcher's, `cpull ci queue`, a patch or stack run). The
  commit page lists it too.
* `/home/patches`, `/home/stacks`, a stack's members and a patch page show the patch's or
  stack's own CI (below).

Balls: blue passed, red failed, pulsing running/queued, yellow passed but on older commits than
the branch holds now, grey cancelled or none.

## CI for patches and stacks

* **Run CI** on a patch page (or `cpull ci patch REPO PATCH [-w]`, MCP `ci_patch`) queues
  `build` and `test` of every idl project in the patch's repo, with the patch's source branch
  tip checked out.
* **Run CI** on a stack page (or `cpull ci stack STACK [-w]`, MCP `ci_stack`) does it for
  every member repo at once, all members' branches checked out together.
* The jobs run in a work tree of their own, `.pull/cpull/ci/work/<subject>/`: a pull-style
  workspace with a linked git worktree of each repo the job needs at the same path as in the
  workspace, and a copy of the pullfile. Those repos are the members (at their source tips)
  and the repos the projects' targets live in (`idl list`'s dirs, e.g. `../commons-ios`), at
  the workspace's current commits, since idl projects depend on sibling repos and reject
  symlinks. `PULL_ROOT` is the work tree. A subject keeps its tree between runs (`checkout
  --detach --force` + `git clean -fd`, so ignored build output stays for incremental builds).
* Each job records its subject (`patch:<repo>:<id>` / `stack:<id>`) and the commits it checked
  out (`checkout`, one `<repo> <oid>` line each); both are in the job JSON and on the job page.
  Retrying such a job reruns it on the same commits. The CI dashboard's per-project history,
  health and progress estimates count workspace jobs only.

### The merge gate

```xml
<key>cpull</key>
<dict>
    <key>require_ci</key>
    <true/>
</dict>
```

With `require_ci`, a stack merges (stack page, `cpull stack merge`, `pull cpull merge`, MCP
`cpull_merge`) only when the CI is green for every member repo that has idl projects, at the
commits their branches hold now: the stack's own latest run, or else each member patch's. A
member without idl projects doesn't need CI. `--force` (`pull cpull merge --force`, MCP
`force`, the stack page's "Merge without green CI") merges anyway. `GET /ci/api/stack/<id>`
returns the stack's CI and the gate's verdict; MCP `cpull_stack` prints them.

## Failed CI -> issue

When a workspace job (not a patch or stack job) passes or fails on a repo checked out on its
pullfile branch:

* a failure files one issue labelled `ci` in that repo per failing target (project, command,
  targets, configuration), titled ``CI: `idl build` in core fails``, with a link to the job and
  the end of its log; the next failure of the same target comments on it (reopening it if it
  was closed);
* the next pass comments and closes it.

The issue a target maps to is kept in the CI db (`ci_issues`), and every job reported on an
issue is linked to it (`issue_jobs`), so the issue page lists them. `<key>ci_issues</key><false/>`
in the `cpull` section turns this off. The issues are written as pull's identity, like every
workspace write.

## Commit <-> issue links

* `#<id prefix>` (6 to 32 hex digits, e.g. `#98e371c9`) in a commit message, a patch or issue
  description or a stack description names an issue: in the repo's own issues first, then the
  workspace's events repo (a stack's description: any repo). The commit page, the history
  (when the summary line has one), and descriptions link it.
* `fixes #id`, `closes #id`, `resolves #id` (any tense, case, optional colon) close the issue
  once the commit is on the repo's pullfile branch: the server polls every repo's branch tip
  (every `--ci-watch-interval` seconds with `--ci-watch`, else 30s) and reads the commits that
  arrived since the tip it last saw (`link_tips` in the CI db; the first look only records the
  tip). It comments "Closed by commit ..." and closes the issue if it's still open, so each
  commit is handled once and a reopened issue stays open. A stack merge lands its commits, so
  merging a stack closes what its commits fix. `<key>close_issues</key><false/>` turns this off.
* An issue page lists its **References**: commits on any local branch of its repo (of every
  repo, for a workspace issue) from the last two years that mention it, with their CI ball and
  whether they close it; patches and stacks that mention it; and the CI jobs reported on it.

## Shutdown

On SIGTERM, SIGINT or SIGHUP the server stops claiming jobs, SIGTERMs every running job's process
group, waits up to 5s (those jobs are recorded as cancelled), SIGKILLs what's left, then dies of
the signal as before. A second signal exits at once.
