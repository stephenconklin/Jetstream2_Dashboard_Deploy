# Command cheat sheet

Every command worth knowing when you're operating or maintaining a deployment
from a terminal, grouped by task. Where
[Command line equivalents](command-line.md) maps each button in the
application to the command behind it, this page goes further: raw Docker,
nginx, and host-level commands that the application never runs but that
answer "why isn't it working?" fastest.

Run everything from the tooling directory unless a command uses an absolute
path:

```bash
cd ~/Jetstream2_Dashboard_Deploy
```

Names below assume the defaults: container and image `dashboard-app`, watchdog
`dashboard-autoheal`. If you deployed under a different image name, substitute
it.

---

## Check a project before deploying

Strictly read-only — builds nothing, writes nothing into the project.

```bash
./deploy/build_and_run.sh --dry-run /path/to/project              # framework, main file, data, base image, code notes
./deploy/build_and_run.sh --dry-run --porcelain /path/to/project  # same, as key=value
```

## Deploy

```bash
./deploy/build_and_run.sh /path/to/project                                 # auto-detect everything
DATA_DIR=/media/volume/<name> ./deploy/build_and_run.sh /path/to/project   # data mounted from a volume
BUNDLE_DATA=1 ./deploy/build_and_run.sh /path/to/project                   # data/ published inside the image
DATA_SUBDIR=Inputs DATA_DIR=/media/volume/<name> ./deploy/build_and_run.sh /path/to/project
ENTRY_FILE=water_quality.R ./deploy/build_and_run.sh /path/to/project      # name the main file
FRAMEWORK=dash ./deploy/build_and_run.sh /path/to/project                  # force the framework
BASE_IMAGE=rocker/geospatial:4.4.1 ./deploy/build_and_run.sh /path/to/project
```

A long build run from a terminal dies with the terminal. Run it inside `tmux`
instead: `tmux new -s build`, detach with Ctrl-b then d, reattach with
`tmux attach -t build`.

## Test dashboards

One minimal example per framework, plus one shaped like a real researcher
project (non-`app.R` main file, data beside the code, a stale renv
`.Rprofile`). Useful for demos and for checking a change end to end.

```bash
./deploy/build_and_run.sh examples/r-shiny-hello-world
./deploy/build_and_run.sh examples/dash-hello-world
./deploy/build_and_run.sh examples/python-shiny-hello-world
./deploy/build_and_run.sh examples/streamlit-hello-world
./deploy/build_and_run.sh examples/r-shiny-researcher-style
```

## Manage the running dashboard

```bash
./deploy/manage.sh health      # which layer is broken: app, nginx, or the public path
./deploy/manage.sh status      # running/stopped, and where it was deployed from
./deploy/manage.sh url         # the public address
./deploy/manage.sh logs [N]    # recent output; for R Shiny, appends the last 3 worker logs
./deploy/manage.sh restart     # also starts a stopped dashboard
./deploy/manage.sh stop        # stays stopped, including across a reboot
./deploy/manage.sh disk        # free space and Docker's usage
./deploy/manage.sh cleanup     # the safe subset; never removes the dashboard image
./deploy/manage.sh report      # a diagnostic report to send for help
```

`status`, `health`, `disk` and `cleanup` accept `--porcelain` for key=value
output.

## Start, stop, reset and remove

```bash
docker start dashboard-app                 # bring back a stopped dashboard without rebuilding
docker restart dashboard-app
docker rm -f dashboard-app                 # remove the container; the image stays, so a redeploy is quick
docker rmi dashboard-app                   # also remove the image; the next publish rebuilds from scratch
docker restart dashboard-autoheal          # if `manage.sh health` reports the watchdog down
docker ps -a --filter name=lockgen         # a lockfile-generation container left by a cancelled R build
docker rm -f dashboard-app-lockgen dashboard-app-uvgen   # remove such leftovers
```

!!! tip "Making the application look like a fresh install"

    Stopping the dashboard isn't enough: the stopped container still carries
    its provenance labels, and the application reopens tabs 1–3 on that
    project. Close the application, run `docker rm -f dashboard-app`, then
    reopen it.

## Inspect the running dashboard

```bash
docker ps -a                                                # all containers, including stopped
docker logs -f --tail 100 dashboard-app                     # follow output live
docker stats --no-stream dashboard-app                      # memory and CPU now
docker exec -it dashboard-app bash                          # a shell inside the container
docker port dashboard-app                                   # which host port it publishes on
docker inspect -f '{{.State.StartedAt}} restarts={{.RestartCount}}' dashboard-app   # crash-looping?
docker inspect -f '{{.State.Health.Status}}' dashboard-app                         # what autoheal reacts to
docker inspect -f '{{json .State.Health}}' dashboard-app | python3 -m json.tool    # recent health checks and their output
docker inspect -f '{{json .Config.Labels}}' dashboard-app   # where it was deployed from
docker inspect -f '{{json .Mounts}}' dashboard-app          # is the data volume actually mounted?
docker exec dashboard-app ls -la /srv/shiny-server/data     # R Shiny: what the app sees as data/
docker exec dashboard-app ls -la /app/data                  # Python frameworks: the same
```

## R Shiny error logs

`docker logs` for an R Shiny container is only Shiny Server's own output. The
app's errors — the real cause behind "An error has occurred" in the browser —
are in per-session worker logs inside the container.

```bash
docker exec dashboard-app sh -c 'ls -t /var/log/shiny-server/ | head'
docker exec dashboard-app sh -c 'tail -50 /var/log/shiny-server/$(ls -t /var/log/shiny-server/ | head -1)'
docker cp dashboard-app:/var/log/shiny-server ./shiny-logs   # copy them out to read or send
```

## Builds started from the application

The application runs builds detached, so they survive a dropped remote-desktop
session or a closed window.

```bash
./deploy/gui/launch_gui.sh                                  # what the desktop icon runs
ls -t ~/dashboard-deploy-logs | head                        # most recent build logs
tail -f ~/dashboard-deploy-logs/$(ls -t ~/dashboard-deploy-logs | head -1)   # follow the current build
cat ~/.local/state/dashboard-deploy/current.pid             # the build the application will reattach to
```

## Images and disk

```bash
docker images                              # every image and its size
docker system df                           # Docker's disk use by category
docker image prune -f                      # dangling images (part of `manage.sh cleanup`)
docker builder prune -f                    # build cache (part of `manage.sh cleanup`; next build is slower)
du -sh ~/dashboard-deploy-logs             # build logs accumulate here
df -h / /var/lib/docker                    # root disk, where images live
```

!!! warning "Avoid the `-a` variants"

    `docker system prune -a` and `docker image prune -a` remove the tagged
    dashboard image and the autoheal image — a full rebuild, and a re-pull
    for the watchdog. `docker container prune` deletes a stopped dashboard
    container, which is exactly what you have right after pressing Stop.

## Volumes and data

```bash
lsblk; findmnt                             # attached disks and where they're mounted
du -sh /media/volume/<name>                # how big the data is
./deploy/lib/persist_mount.sh --check <uuid> /media/volume/<name>   # will the mount survive a reboot? (no root needed)
```

## nginx and the network

```bash
sudo ss -tlnp | grep -E ':80|:8080'        # expect nginx on 0.0.0.0:80, the app on 127.0.0.1 only
cat /etc/dashboard-deploy/proxy.env        # the topology the tooling believes in
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/_deploy/health   # nginx alone, without the app
sudo nginx -t                              # validate the config
sudo systemctl reload nginx                # apply it without dropping connections
systemctl status nginx --no-pager
sudo tail -f /var/log/nginx/dashboard.access.log   # who is visiting, live
sudo tail -f /var/log/nginx/dashboard.error.log    # 502s, upstream errors, rate-limit rejections
cat /etc/nginx/sites-available/dashboard   # the generated site config
```

`8080` is the default `APP_HOST_PORT`; if `deploy/deploy.env` sets another,
grep for that instead.

!!! warning "Don't hand-edit the nginx site"

    `bootstrap.sh` regenerates it from the template on every run. Change
    `deploy/deploy.env` and re-run bootstrap instead.

## Host setup

One-time, as root, and safe to re-run — re-running is how a `deploy.env`
change is applied.

```bash
cp deploy/deploy.env.example deploy/deploy.env        # optional: domain, port, swap, toggles
sudo ./deploy/bootstrap.sh                            # provision the host
sudo ./deploy/bootstrap.sh /path/to/project           # provision, then deploy
sudo ./deploy/bootstrap.sh --check                    # read-only status
sudo ./deploy/bootstrap.sh --remove-proxy             # roll back to direct port-80 binding
```

## Host health

```bash
free -h; swapon --show                     # memory and swap (R builds are memory-hungry)
uptime                                     # load average
sudo journalctl -u docker --since "1 hour ago" --no-pager   # Docker daemon problems
sudo dmesg -T | grep -i -E 'killed process|out of memory'   # was something OOM-killed?
sudo certbot certificates                  # certificates and expiry (only with a DNS name configured)
```

## Working on the repository

```bash
./deploy/lint.sh                           # shellcheck every tracked .sh, then a syntax check of deploy/gui
git config core.hooksPath .githooks        # one-time: lint automatically on commit
pip install -r docs/user-guide/requirements.txt && mkdocs serve   # preview this guide
```

The pre-commit hook only runs when a `.sh` file is staged, so after a
Python-only change to the application, run `lint.sh` by hand.
