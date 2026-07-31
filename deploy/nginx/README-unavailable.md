# `unavailable.html`

Served by nginx for 502/503/504 — whenever the dashboard container is
rebuilding, stopped, or crashed. `bootstrap.sh` installs it to
`<MAINTENANCE_ROOT>/_deploy/unavailable.html`.

The rationale used to live in an HTML comment inside the file, which meant it
was served to every visitor who viewed source. It lives here instead.

**Deliberately plain and self-contained**: no external CSS, fonts or images.
Whatever is broken may well be the reason a request failed in the first place,
and a maintenance page that itself fails to load is worse than none.

**Written for the visitor, not the operator.** The people most likely to see
this are colleagues opening a link, not whoever deployed the dashboard — so it
says what to do (wait and reload) rather than what went wrong. The one
operator-facing line, pointing at `manage.sh health`, is deliberately last and
visually quiet.

It carries `Retry-After: 30` and `Cache-Control: no-store`, so a browser or
intermediary does not keep showing it after the dashboard comes back.
