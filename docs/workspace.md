A [pull](https://github.com/jbisfun/pull) workspace is a directory with a `pullfile.plist` listing repos that move together, each cloned under it (nested ones as `group/name`). Workspace mode is local mode over all of them at once, plus *stacks*: changes that span several repos and land together.

Running it

* Run `haxy` anywhere inside a workspace (outside its member repos), or name one with `haxy --workspace DIR`. Inside a member repo, plain `haxy` still gives local mode for just that repo.

* `pull haxy open` does the same from pull. It first sets every repo's `user.name` and `user.email` to pull's identity (`pull whoami`), then runs `haxy --workspace ROOT`.

No accounts

* Like local mode, workspace mode has no accounts. There are no login, signup, user, key, password or settings pages or routes, and no admin database: whoever can reach the port can read and write.

* Every write is authored by the `user.name` and `user.email` in that repo's own git config, which `pull haxy open` sets to pull's identity. Unlike plain local mode, the global git config is never used for this. A repo without them refuses the write, with a message saying to start haxy through pull.

* The web UI only accepts form posts from its own origin, so other websites can't write through it. Only bind it to addresses you trust everyone on.

Running it as a server

* `--web-listen ADDR` turns off the TUI. Haxy then serves only the web UI on exactly ADDR, and keeps serving until it is killed. It never reads the terminal, so it can run as a background job nobody is attached to:

  ```
  pull haxy open --web-listen 127.0.0.1:8080
  ```

* As a pull job, add this to the pullfile's `jobs` array. Jobs run from the workspace root, with the workspace env:

  ```xml
  <dict>
      <key>Label</key>
      <string>haxy</string>
      <key>ProgramArguments</key>
      <array>
          <string>pull</string>
          <string>haxy</string>
          <string>open</string>
          <string>--web-listen</string>
          <string>127.0.0.1:8080</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <dict>
          <key>SuccessfulExit</key>
          <false/>
      </dict>
  </dict>
  ```

* Running `haxy --workspace DIR --web-listen ADDR` directly works too, but then nothing sets the repos' identity. Repos that pull hasn't set up yet refuse writes.

* This is not `haxy serve`. That is the multi-user server with accounts, SSH and pushes; see [host.md](host.md).

The events repo

* The workspace's own issues and its stacks live on the `haxy/events` branch of one repo. If the workspace root is a git repo itself, it's that repo. Otherwise, name one of the pullfile repos in the pullfile's `haxy` section:

  ```xml
  <key>haxy</key>
  <dict>
      <key>events</key>
      <string>dotenv</string>
  </dict>
  ```

* Without either, the workspace pages still work, but there are no stacks.

URLs

* `/` is the workspace home: every repo, grouped by its group dir, with its branch, pin and open issue and patch counts.

* `/home/issues`, `/home/patches` and `/home/stacks` gather those across every repo. `/home/stacks/<id>` is one stack, with the patch of each member and what merging it would do.

* Each repo's own pages are at `/<workspace>:<repo>/...`, the same as on a server, where `<workspace>` is the root dir's name. Haxy repo names can't hold `/`, so a nested `group/app` is `group.app`, here and when the repo is pushed to a haxy server. A root events repo is `workspace`.

Stacks

* A stack names one patch per member repo. Open one from repos that have work on a branch with `pull haxy patch` (or `haxy stack new --title T core:feature group/app:feature`). This opens an ordinary patch in each repo and the stack in the events repo.

* The stack event looks like this:

  ```json
  {"id":"<32 hex>","kind":"stack","data":{"title":"rename the api","description":"","labels":"api","members":"core <patch id>\ngroup/app <patch id>","status":{"open":{}}}}
  ```

  * `members` holds one `<pullfile repo> <patch id>` line per repo, 1 to 64 of them.
  * `status` is `{"open":{}}`, `{"closed":{}}` or `{"merged":{"pins":"core <oid>\ngroup/app <oid>"}}`.
  * A merged stack can't be changed. When two copies are synced, merged wins over open or closed if their members agree. Other differing fields become conflicts, like any other event (see [event.md](event.md)).

* Merging (`pull haxy merge ID`, the stack page's merge button, or `haxy stack merge ID`) merges every member's patch into its target branch, or none of them. It never touches a worktree, so it refuses when a target branch is checked out, or when a source has moved past the patch. The stack is then recorded as merged, with the new commits as its pins.

* Haxy doesn't write the pullfile. After merging, the web UI runs `pull haxy pin ID`. This writes the pins into the pullfile and commits it the way pull always commits, signed and through its hooks, so `pull` must be on the PATH of the haxy process.

* Pushing the events repo to a haxy server carries the stacks along. The server checks each stack event the same way on push, but it doesn't show stacks.
