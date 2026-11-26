# cpull

cpull is jbisfun's fork of [haxy](https://github.com/xit-vcs/haxy) by the xit-vcs project, renamed and extended for [pull](https://github.com/jbisfun/pull) workspaces (workspace mode, stacks, a wiki-themed web UI). Everything below that isn't about workspaces is haxy's work.

You're looking at cpull, a git forge that is local-first and text-based. cpull has a text user interface (TUI) that you can view in your terminal or on the web. Get local control of your data and hop on the TUI train!

Here's what it looks like in the terminal and on the web:

<p align="center">
<a href="https://raw.githubusercontent.com/xit-vcs/haxy/refs/heads/master/docs/screenshots/terminal.avif"><img src="docs/screenshots/terminal.avif" width="49%" /></a>
<a href="https://raw.githubusercontent.com/xit-vcs/haxy/refs/heads/master/docs/screenshots/web.avif"><img src="docs/screenshots/web.avif" width="49%" /></a>
</p>

## Why another git forge?

cpull is based around two design ideas:

### 1. Store project metadata (issues, patches, and discussions) in the repo

Keeping project metadata in the repo has a few benefits:

* You can easily replicate it to different cpull instances.
* You can view/edit it locally and push your changes later, just like you do with code.

You can still edit this data via the UI of a cpull instance just like any other git forge. Additionally, however, you can run the cpull binary locally to browse a repo's issues and other metadata offline. If you have push access to the repo, you can make changes locally and push them later.

cpull repos have a special branch called `cpull/events` where events are stored. Any time project metadata is created or updated, an event is created. There's one event per commit, which is stored as JSON in the commit message itself. The server consumes these events into its database when it receives them -- essentially, a form of event sourcing.

[Read more](docs/event.md) about the event system.

### 2. Provide a TUI that is served over SSH, in addition to a web UI

cpull provides a text user interface (TUI) over SSH, so you can browse the cpull instance entirely from your terminal. These are sometimes called SSH apps. One big advantage they have is that you are automatically authenticated with your SSH key, so creating an account on a cpull instance and associating it with your SSH public key can be done instantly.

Additionally, cpull provides a web UI for a more typical experience in a web browser. The web UI simply renders the TUI in your browser. This sounds terrifying, but the web renderer still uses standard HTML controls. The renderer runs from a small webassembly binary, but pages are also initially server-rendered so content can be viewed even if scripts are disabled.

[Read more](docs/tui.md) about the TUI.

## How to fire this puppy up and get 'er done

To build, install zig 0.17.0 and do `zig build` and you'll find the binary at `zig-out/bin/cpull`.

The web UI's theme, identicons and code highlighter come from [jbisfun/theme](https://github.com/jbisfun/theme), a path dependency on `../theme` (build.zig.zon). In a [pull](https://github.com/jbisfun/pull) workspace it is the sibling checkout. Anywhere else, clone it next to cpull first.

On a production server you would run this binary with the `serve` subcommand. [Read more](docs/host.md) about self-hosting.

To run it in local mode, just run it with no subcommand in any git repo. It will show a completely offline cpull UI just for that repo. [Read more](docs/local.md) about local mode.

Run it inside a [pull](https://github.com/jbisfun/pull) workspace and it covers every repo in the workspace, plus stacks: changes across repos that land together. `--web-listen 127.0.0.1:8080` serves just that account-less web UI, as a background job. [Read more](docs/workspace.md) about workspace mode.

The easiest way to try cpull out is like this:

```
zig build try
```

This will launch a server with fake data that it stores in the `temp-try` directory. It will then launch the TUI directly in your terminal (you can exit by pressing escape). Additionally, you can view the web UI at http://localhost:8080.

A fun test is to push cpull itself to the server. You can do that by running the following command, which will push it to the server using SSH:

```
GIT_SSH_COMMAND='ssh -p 8022 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i temp-try/key' git push localhost:admin:cpull HEAD:master
```

After that, go to the admin user in the UI and you'll see cpull's repo page: http://localhost:8080/admin:cpull/files/branch:master

*"C'mon Alex! You always dreamt about going on a big adventure! Let this be our first!" -- Lunar: Silver Star Story*
