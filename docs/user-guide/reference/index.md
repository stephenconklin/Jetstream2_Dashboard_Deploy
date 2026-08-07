# Technical reference

The guide is deliberately light on mechanism. This section is where the
mechanism lives — for when you need to know exactly what happens, or you're
maintaining the tooling rather than using it.

---

<div class="grid cards" markdown>

-   :material-book-open-variant: **[Full deployment reference](deployment.md)**

    The complete account: provisioning, the nginx front end, framework
    detection, every environment variable, health checks, version pinning, and
    the reasoning behind each design decision.

    Written for someone comfortable in a terminal.

-   :material-file-send: **[Getting files onto the instance](getting-your-files-onto-the-instance.md)**

    Git, drag-and-drop, rsync, cloud storage and Globus — the reference behind
    the application's *Your data* tab.

-   :material-console-line: **[Command line equivalents](command-line.md)**

    Every button in the application, and the command it runs.

</div>

---

## Where things live on the instance

| Path | What it is |
|---|---|
| `~/Jetstream2_Dashboard_Deploy/` | The deployment tooling |
| `~/dashboard-deploy-logs/` | Build logs and diagnostic reports |
| `/media/volume/<name>/` | Your attached storage volumes |
| `/etc/dashboard-deploy/proxy.env` | Records that nginx is in front |
| `/etc/nginx/sites-available/dashboard` | The generated nginx site (**don't edit — regenerated**) |
| `/var/log/nginx/dashboard.error.log` | Proxy-side errors |

## Key facts in one place

| | |
|---|---|
| Container name | `dashboard-app` |
| Public port | 80 (443 with TLS configured) |
| Internal ports | 3838 R Shiny · 8050 Dash · 8000 Python Shiny · 8501 Streamlit |
| Data mount target | `/srv/shiny-server/data` (R) · `/app/data` (Python) |
| Reserved URL prefix | `/_deploy/` — never proxied to your app |
| Low-disk warning | Below 15 GB free on `/` |
| Startup grace period | 300 seconds |

## The two scripts

**`bootstrap.sh` provisions the host. `build_and_run.sh` provisions the app.**
That split is the organising principle of the whole repository — bootstrap
knows nothing about frameworks, and `build_and_run.sh` never needs root.

```bash
sudo ./deploy/bootstrap.sh          # once per instance: Docker, nginx, swap, TLS, watchdog
./deploy/build_and_run.sh <project> # every time your code changes
./deploy/manage.sh health           # which layer is broken
```

---

## For maintainers

Design rationale for the repository itself — why detection is content-based,
why the GUI is a thin layer, why the proxy state file exists — is in
[`CLAUDE.md`](https://github.com/stephenconklin/Jetstream2_Dashboard_Deploy/blob/main/CLAUDE.md)
at the repository root, alongside
[Developing on this repo](deployment.md#developing-on-this-repo).
