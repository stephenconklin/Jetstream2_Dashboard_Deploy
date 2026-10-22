# Share and update your dashboard

Your dashboard is live. This page covers what to do with it.

---

## Your address

```
http://<your-instance-ip>/
```

For example `http://149.165.170.42/`, or `https://your-name/` once you've
given it [a domain name](#can-i-get-https). Anyone, anywhere, with a browser can open
it. No login, no VPN, no Jetstream2 account needed.

The address is **stable for the life of the instance**. Rebooting doesn't change
it, republishing doesn't change it, resizing doesn't change it. Deleting the
instance does.

!!! tip "Where to find it again"

    - The application's **Manage** tab shows it in the headline
    - Exosphere shows it on the instance page
    - It's the instance's floating IP — the number you noted in Part 1

---

## Before you share it widely

A short list worth walking before it goes in a paper or a mailing list.

- [ ] **Open it in a private/incognito window.** This catches anything that
      only works because *your* browser has state. It's also the closest thing
      to seeing what a stranger sees.
- [ ] **Try it on a phone.** Not every dashboard is usable on a small screen,
      but it's better to know.
- [ ] **Click everything.** Every tab, every dropdown, every plot. A dashboard
      that publishes fine can still throw an error on the one control nobody
      tested.
- [ ] **Check what it exposes.** Everything the dashboard can display, a
      visitor can see. Is any of your data sensitive, unpublished, or under
      embargo?
- [ ] **Consider the load.** An `m3.small` handles a research group
      comfortably. A link in a widely-read newsletter is a different
      proposition — resize the instance up beforehand.
- [ ] **Reboot the instance once** from Exosphere, and confirm the dashboard
      comes back with its data. This tests the volume mount properly, and
      finding out now beats finding out in six months.

!!! danger "It really is public"

    There is no access control. If your dashboard shows anything you wouldn't
    put on a public web page — participant data, unpublished results,
    site coordinates for a protected species — do not publish it this way. See
    [Questions people ask](../help/faq.md#is-my-dashboard-private).

---

## Citing it

For a paper or a report, quote the address and the date, and say what it runs
on:

> Interactive dashboard available at http://149.165.170.42/ (accessed
> 7 August 2026). Deployed on Jetstream2 (Hancock et al., 2021).

Two things make a citation more durable than an IP address alone:

1. **Put your code in a repository and cite that too** — GitHub plus a
   [Zenodo](https://zenodo.org/) DOI for the release. Code and data outlive any
   particular server.
2. **Consider a DNS name** (below). `salmon.myuniversity.edu` survives a
   rebuild onto a different IP; a bare number does not.

---

## Can I get `https://`? { #can-i-get-https }

Yes, if you have a **domain name**: either your own, or a name your
institution gives you, such as `salmon.myuniversity.edu`. Certificate
authorities won't issue a certificate for a bare IP address, so
`https://149.165.170.42/` isn't possible at any price.

Without a domain name, nothing changes: your dashboard stays at
`http://<your-instance-ip>/` and works exactly as before.

With one, it takes two steps:

1. **Point the name at your instance.** The name needs a DNS **A record**
   containing your instance's IP address. Usually your institution's IT
   department adds it for you; if you bought the domain yourself, it's in your
   registrar's DNS settings. A new record can take up to an hour to work.
2. **In the application, on the Manage tab**, type the name under
   [Web address](step4-manage.md#web-address) and press **Check**. Once it
   says the name points to this server, press **Use this name with HTTPS**.

That's all. The application gets a free certificate from Let's Encrypt,
switches your dashboard to `https://your-name/` (the old `http://` addresses,
including the IP, redirect there), and renews the certificate automatically
from then on. Nothing needs a terminal, a password or an email address.

If anything goes wrong, nothing is changed and your dashboard stays at its
current address. The message says why; the usual reason is a DNS record that
hasn't appeared yet. To go back to the IP address later, press **Stop using
this name**.

??? info "From a terminal instead"

    ```bash
    cd ~/Jetstream2_Dashboard_Deploy
    ./deploy/lib/domain.sh salmon.myuniversity.edu        # does it point here?
    sudo ./deploy/bootstrap.sh --set-domain salmon.myuniversity.edu
    sudo ./deploy/bootstrap.sh --clear-domain             # back to the IP
    ```

    Full detail: [TLS](../reference/deployment.md#tls).

---

## Updating your dashboard

<div class="grid cards" markdown>

-   :material-database-sync: **Changed the data**

    **Data on a storage volume:** upload the new files there, then press
    **Restart** on the Manage tab. **Seconds** — no rebuild, since that data
    is attached at run time.

    **Data in your app folder:** update the files there, then press
    **Publish again**. It's published with the app, so it changes when the
    app does.

-   :material-code-tags: **Changed the code**

    Get the new code onto the instance, then press **Publish again**.

    **Minutes.** Much faster than the first build, because everything unchanged
    is reused.

</div>

### The code-change loop

If your project is in Git — the arrangement worth setting up for:

```bash
# on your own computer
git add -A && git commit -m "fix the site filter" && git push

# on the instance, in a terminal
cd ~/my-dashboard && git pull
```

Then press **Publish again** on the Manage tab. Your live dashboard keeps
serving until the new build is ready, so visitors see no gap.

If you'd rather not use a terminal at all, go to tab 1 and download from the Git
address again — it fetches the current version.

---

## Keeping it running

Two things you should know about, and neither needs action right now.

**It restarts itself.** If your dashboard crashes, it is restarted
automatically. If it stops responding without crashing — wedged rather than
dead, which is the harder failure — a watchdog notices and restarts it within a
few minutes. An outage that would have lasted until somebody noticed lasts
minutes instead.

**It survives reboots.** If the instance reboots — Jetstream2 maintenance, a
resize, a power event — your dashboard starts again automatically, *provided*
your data volume remounts. Which is exactly what
[Make it survive a reboot](step2-your-data.md#make-it-survive-a-reboot) is for.

The one exception: a dashboard you stopped yourself with the **Stop** button
stays stopped, deliberately, including through reboots.

### A maintenance habit

Every few months:

- [ ] Open it and click through it
- [ ] Check **Storage** on the Manage tab; press **Free up space** if tight
- [ ] Check **Restarts** in Details — a high number means it's been struggling

### Shutting it down for good

When you're finished with a dashboard:

1. **Shut down the instance** in Exosphere. Billing stops. The volume and the
   instance both still exist, so you can start it again later.
2. **Delete the instance** when you're sure. This frees the IP address, and the
   address is gone for good.
3. **Delete the volume separately** if you no longer need the data. Deleting
   the instance does *not* delete the volume — that's the point of it, but it
   does mean an orphaned volume keeps billing quietly.

!!! tip "Take a snapshot first"

    Exosphere can save an instance as an image before you delete it. That
    preserves the whole configured machine, so you can recreate it later
    without redoing any of this guide.

---

## :material-check-all: You're done

You now have a dashboard on the public internet, at a stable address, that
restarts itself when it fails and comes back after a reboot.

If something goes wrong later → **[When something goes wrong](../help/troubleshooting.md)**
