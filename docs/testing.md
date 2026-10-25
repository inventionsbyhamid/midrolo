# Testing

The suite is RSpec: models, services, requests, jobs, tasks, views, and system specs that drive headless Chrome
through Cuprite. It needs Postgres 16 and, for the system specs, a Chrome or Chromium.

## Locally

```sh
bin/rails db:test:prepare
bundle exec rspec spec/models/show_spec.rb   # one file
bundle exec rspec                            # everything: about 12 minutes on the Mac, so prefer the remote lane
```

- `SKIP_NETWORK=1` leaves out the `:network` specs (the MapLibre CDN) when you are offline.
- `HEADFUL=1` shows the browser while system specs run.

## On ioflood: `bin/remote-rspec`

The Mac is small; ioflood isn't. `bin/remote-rspec` runs the suite there in throwaway containers and streams the
output back. It takes the same arguments as `rspec`, and with none it runs the whole suite.

```sh
bin/remote-rspec                                   # the whole suite
bin/remote-rspec spec/system/media_kit_spec.rb     # one file (spec/x_spec.rb:12, --tag, -e ... all work)
bin/remote-rspec --rebuild                         # rebuild the image from a fresh base first
bin/remote-rspec --keep spec/system                # leave the containers behind to poke at
bin/remote-rspec --clean                           # delete this lane's copy of the source on ioflood
```

Options go before the rspec arguments. It needs `ssh ioflood` to work, which means the VPN is on.

`bin/ci` (setup, RuboCop, the audits and Brakeman) ends with the suite, run locally; `REMOTE_RSPEC=1 bin/ci` runs
the suite through `bin/remote-rspec` instead.

What a run does:

1. Checks ioflood's load. Above 30 (1-minute), or under 12 GiB of available memory, it waits 30 s and checks again,
   up to 10 minutes, then gives up with exit 75.
2. Locks the lane and rsyncs the working tree to `/root/midrolo-ci/src/<lane>/`. The lane is this checkout's
   directory name, so worktrees each get their own copy and run side by side; two runs from one checkout wait for each
   other. `--lane NAME` picks another. Git data, `tmp/`, `log/`, `storage/`, built assets, `.env*` files, key files
   and `spec/fixtures/private/` are never sent. The one `.env` file that is sent is `.env.example`, which holds no
   values and which a spec reads.
3. Builds `midrolo-ci:test` from `ci/Dockerfile.test` if that file changed (Ruby 3.4.1, Chromium, fonts, libvips,
   libpq). The source isn't in the image, and gems live in the `midrolo-ci-bundle` volume, so a Gemfile change only
   costs a `bundle install`.
4. Starts `midrolo-ci-db-<run>` (Postgres 16 on tmpfs, password made fresh for the run) and runs
   `midrolo-ci-runner-<run>`, which does `bundle install`, `db:create db:schema:load`, `tailwindcss:build` and
   `bundle exec rspec <your args>` with `RAILS_ENV=test CI=1`.
5. Removes both containers, prints rspec's exit status, the time taken and ioflood's load before and after, and
   exits with rspec's status. If specs failed, system spec screenshots are copied to `tmp/remote-rspec/`.

`SKIP_NETWORK` is passed through when set. `MIDROLO_CI_TIMEOUT` (seconds, default 3600) stops a run that hangs.

The pieces: `bin/remote-rspec` (runs on the Mac), `ci/remote-run` (runs on ioflood), `ci/run-tests` (runs in the
runner container), `ci/Dockerfile.test`.

## Safety rules on ioflood

ioflood is a shared production server (Coolify and several other apps and databases). The remote lane keeps to
these rules, and so should anyone changing it:

- It creates and removes only Docker objects named `midrolo-ci*`: containers `midrolo-ci-db-<run>` and
  `midrolo-ci-runner-<run>`, network `midrolo-ci-net`, volume `midrolo-ci-bundle`, images `midrolo-ci:test` and
  `midrolo-ci:postgres16`. Files go only under `/root/midrolo-ci/`.
- Never `docker system prune`, `docker volume prune` or `docker network prune`, and never stop, restart or change
  anything else.
- No `--network host`, no published ports. The containers talk on `midrolo-ci-net`; Capybara and Chromium share the
  runner.
- Caps: the runner gets 8 CPUs, 8 GB (no swap) and 4096 pids; the database 2 CPUs, 2 GB and 512 pids.
- The load gate above, before every run.
- Containers go when the run ends, on failure and on Ctrl-C or `kill` too. If the connection drops mid-run, nothing
  on the Mac can reach ioflood, so the containers clean up after themselves: both run with `--rm`, rspec gets SIGINT
  at the timeout, and the database stops itself 10 minutes after that.

## Cleanup

Each run removes its own containers. The image, the bundle volume, the network and the synced source stay, so the
next run is fast. To check nothing is left running:

```sh
ssh ioflood 'docker ps -a --format "{{.Names}}" | grep midrolo-ci'
```

After `--keep`, remove the run's containers by name (the run id is printed at the start):

```sh
ssh ioflood 'docker rm -f midrolo-ci-runner-<run> midrolo-ci-db-<run>'
```

A worktree's lane outlives the worktree; `bin/remote-rspec --clean` (from that checkout, or with `--lane NAME`)
removes it. To remove the remote lane entirely:

```sh
ssh ioflood 'docker rm -f $(docker ps -aq --filter label=midrolo-ci=1) 2>/dev/null;
  docker rmi midrolo-ci:test midrolo-ci:postgres16; docker volume rm midrolo-ci-bundle;
  docker network rm midrolo-ci-net; rm -rf /root/midrolo-ci'
```

The label filter matches only containers this lane started, all of which carry `midrolo-ci=1`.
