# bin/remote-rspec: build notes (2026-10-25)

How to use it is in [docs/testing.md](../docs/testing.md). This file records how the lane was checked.

## Results on ioflood

| Run | Result | rspec time | Wall time (Mac, end to end) |
| --- | --- | --- | --- |
| Full suite, final scripts | 1321 examples, 0 failures | 2m11.6s | 2m48s |
| Full suite, first run | 1321 examples, 0 failures | 2m14.5s | 2m53s |
| `spec/system/media_kit_spec.rb`, cold (image build + bundle install) | 3 examples, 0 failures | 7.05s | 2m58s |
| `spec/system/media_kit_spec.rb`, warm | 3 examples, 0 failures | 6.36s | 36s |

On the Mac the full suite takes about 12 minutes. ioflood's 1-minute load went from 3.7 to 8.2 during a full run.
The `:network` spec (MapLibre CDN) ran and passed. A warm run spends about 30 s on overhead: the load check, the lock,
rsync, starting Postgres, `db:schema:load`, the Tailwind build and booting Rails.

## Container-only fixes

None were needed. `spec/support/system.rb` already passes `--no-sandbox`, uses 30 s process timeouts, and Ferrum picks
up `BROWSER_PATH`, which the image sets to Debian's chromium. Rails merges `DATABASE_URL` over the `test` entry in
`config/database.yml`, so that file is unchanged. The specs run in UTC in the container, as they do on GitHub CI.

## Behaviour checked by hand

- Caps on the live containers (`docker inspect`): runner 8 CPUs, 8 GiB, no swap, 4096 pids, `--init`, 1 GiB shm;
  database 2 CPUs, 2 GiB, 512 pids, tmpfs data dir, no anonymous volume. Both on `midrolo-ci-net`, with no port
  bindings.
- `midrolo-ci:postgres16` was built from the `postgres:16-alpine` already on the host, with no pull, so no other
  app's image tag was touched.
- A second run in the same lane says the lane is busy and waits. Killing a waiting run leaves no remote process
  behind; the remote side writes a heartbeat and dies of SIGPIPE.
- `kill -TERM` during rspec stops the run within 4 s and removes both containers. The first version waited for
  rspec to finish, because bash defers traps while a foreground command runs. The run's ssh now goes in the
  background behind `wait`.
- TTY mode (`docker run -t` when the Mac's stdout is a terminal) gives colour output and the right exit code.
- `SKIP_NETWORK=1` reaches the container ("Run options: exclude {network: true}").
- `--keep` leaves both containers; `--clean` removes the lane's checkout; an unreachable host exits 69 with "is the VPN
  on?".
- The synced tree has no `.git`, `.env*`, key files or `.claude/`. The exclude list was tested against macOS's
  openrsync, including anchored patterns and the `--delete` behaviour.

## Known limits

- Without a terminal (an agent capturing output, say), Ruby buffers rspec's progress dots, so output arrives in
  chunks rather than live. With a terminal it streams.
- `docker build` takes no CPU cap under BuildKit. The image builds once, in about a minute, and rebuilds only when
  `ci/Dockerfile.test` changes.
- Each lane is a 60 MB copy of the source under `/root/midrolo-ci/src/`. Worktree lanes stay after their worktree is
  gone; remove them with `--clean`.
- The suite runs serially. The project has no parallel runner, and none was added.
