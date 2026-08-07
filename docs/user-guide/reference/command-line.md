# Command line equivalents

The desktop application is a thin front end: every button runs one of the same
shell scripts a terminal user would run. Nothing is hidden, and the two paths
cannot drift apart because there is only one implementation.

This page maps one to the other. Run everything from the tooling directory:

```bash
cd ~/Jetstream2_Dashboard_Deploy
```

---

## Tab 1 · Your app

| In the application | On the command line |
|---|---|
| Selecting a folder, and the report it prints | `./deploy/build_and_run.sh --dry-run /path/to/project` |
| The same, as parseable `key=value` | `./deploy/build_and_run.sh --dry-run --porcelain /path/to/project` |
| **Download** from a Git address | `git clone <url> ~/my-dashboard` |
| **Unpack it** from a `.zip` | `unzip ~/my-dashboard.zip -d ~/` |

The dry run is strictly read-only: it starts nothing, writes nothing into your
project, and reports a missing dependency file rather than failing on it.

---

## Tab 2 · Your data

| In the application | On the command line |
|---|---|
| The list of locations | `lsblk -J -b` and `findmnt -J -b` |
| **Look in that folder now** | `ls -lh /media/volume/<name>/` · `du -sh` · `df -h` |
| **Make this permanent** | `sudo /usr/local/libexec/persist_mount.sh <uuid> /media/volume/<name> ext4` |
| Checking without changing | `./deploy/lib/persist_mount.sh --check <uuid> /media/volume/<name>` |

Transfer routes are covered in
[Getting files onto the instance](getting-your-files-onto-the-instance.md).

---

## Tab 3 · Publish

| In the application | On the command line |
|---|---|
| **Publish my dashboard** | `DATA_DIR=/media/volume/<name> ./deploy/build_and_run.sh /path/to/project` |
| **Force framework** | `FRAMEWORK=dash ./deploy/build_and_run.sh …` |
| **Base image** | `BASE_IMAGE=python:3.9-slim ./deploy/build_and_run.sh …` |
| **App's internal port** | `CONTAINER_PORT=8080 ./deploy/build_and_run.sh …` |
| **Stop** a running build | ++ctrl+c++ |

A full deploy with everything specified:

```bash
DATA_DIR=/media/volume/salmon-data \
BASE_IMAGE=rocker/geospatial:4.4.1 \
./deploy/build_and_run.sh ~/salmon-dashboard
```

The application runs builds **detached** so they survive a dropped desktop
session. To get the same from a terminal, use `nohup`, `tmux` or `screen`:

```bash
tmux new -s build
./deploy/build_and_run.sh ~/salmon-dashboard
# detach with Ctrl-b d, reattach later with: tmux attach -t build
```

---

## Tab 4 · Manage

| In the application | On the command line |
|---|---|
| The headline and **Details** | `./deploy/manage.sh health` |
| The same, as `key=value` | `./deploy/manage.sh health --porcelain` |
| Is it up? | `./deploy/manage.sh status` |
| **Open dashboard** | `./deploy/manage.sh url` |
| **Restart** / **Start** | `./deploy/manage.sh restart` |
| **Stop** | `./deploy/manage.sh stop` |
| **Show latest** log | `./deploy/manage.sh logs [N]` |
| **Storage** panel | `./deploy/manage.sh disk` |
| **Free up space** | `./deploy/manage.sh cleanup` |
| **Save a report to send for help** | `./deploy/manage.sh report` |
| **Publish again** | re-run `build_and_run.sh` |

`status`, `health`, `disk` and `cleanup` all accept `--porcelain`.

### The raw Docker equivalents

`manage.sh` is a wrapper. Underneath:

```bash
docker ps                                # what's running
docker ps -a                             # including stopped
docker logs dashboard-app                # your app's output
docker logs -f --tail 100 dashboard-app  # follow it live
docker stats --no-stream dashboard-app   # memory and CPU now
docker restart dashboard-app
docker exec -it dashboard-app bash       # a shell inside the container
```

!!! note "Why `manage.sh logs` and not `docker logs`"

    `manage.sh logs` merges stderr into stdout deliberately. Shiny Server,
    gunicorn and Streamlit all log to **stderr**, so anything capturing stdout
    alone comes back empty and looks broken.

---

## Host provisioning

Not exposed in the application at all — it's a one-time setup that the prepared
image has already done.

```bash
sudo ./deploy/bootstrap.sh              # provision; safe to re-run
sudo ./deploy/bootstrap.sh <project>    # provision, then deploy
sudo ./deploy/bootstrap.sh --check      # read-only status snapshot
sudo ./deploy/bootstrap.sh --remove-proxy   # roll back to direct port 80
```

Re-running it is the normal way to apply a change from `deploy/deploy.env` —
adding a domain name for TLS, for instance. Every step detects existing state
and skips.

---

## Useful checks

```bash
# Is the app exposed to the internet, or only reachable through nginx?
sudo ss -tlnp | grep -E ':80|:8080'
# Expect nginx on 0.0.0.0:80 and docker-proxy on 127.0.0.1:8080 ONLY.

# What the tooling believes the topology is
cat /etc/dashboard-deploy/proxy.env

# nginx alone, without involving your app
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/_deploy/health

# What the watchdog is reacting to
docker inspect -f '{{.State.Health.Status}}' dashboard-app

# Where the running dashboard was published from
docker inspect -f '{{json .Config.Labels}}' dashboard-app
```

That last one is how the application restores tabs 1–3 when you reopen it: the
running container records its own origin, so there's no state file to go stale.

---

Everything here in far more detail:
**[Full deployment reference](deployment.md#command-reference)**.
