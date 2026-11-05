"""Run On (lab.sh runon), as Redde uses it: a scheduled job's own model.

  dashboard  the job's model and provider set by the Dashboard's job update (as the app does on that
             connection); triggered, the run reaches the stub on that model ("beta"), not the main
             one ("alpha").
  api        the Hermes API can't set a job's model: the app renames the job with
             ` [redde-model:<model>|<provider>]` over PATCH api/jobs; the Redde plugin gives the job
             that model and takes the mark off within a minute, and the run is on it.
  main       `/redde-push job-model default <job> - -` puts it back on the main model at once.

usage: runon_check.py   (a lab up with the push scenario)
"""
import asyncio
import json
import os
import time

import check
from check import Dashboard, api, report
from status_check import rest, rest_opener

HITS = os.environ["LAB_HITS"]
PROVIDER = "custom:my-local"


def jobs(opener):
    listed = rest(opener, "GET", "/api/cron/jobs?profile=default")
    return listed if isinstance(listed, list) else listed.get("jobs") or []


def job(opener, job_id):
    return next((j for j in jobs(opener) if j.get("id") == job_id), {})


def hits_since(count):
    try:
        lines = open(HITS).read().splitlines()
    except OSError:
        return []
    return [json.loads(line) for line in lines[count:] if line.strip()]


def hit_count():
    try:
        return len(open(HITS).read().splitlines())
    except OSError:
        return 0


async def run_on(opener, job_id, deadline=150):
    """Triggers the job; the models its run reached (the stub's record of each call)."""
    before = hit_count()
    rest(opener, "POST", f"/api/cron/jobs/{job_id}/trigger?profile=default")
    end = time.time() + deadline
    while time.time() < end:
        hits = [h for h in hits_since(before) if "runon" in json.dumps(h)]
        if hits:
            return [h.get("model") for h in hits]
        await asyncio.sleep(2)
    return [h.get("model") for h in hits_since(before)]


async def main():
    dash = await Dashboard.connect()
    opener = rest_opener()
    created = rest(opener, "POST", "/api/cron/jobs?profile=default",
                   {"name": "[redde-notify] Lab runon", "schedule": "0 4 * * *", "prompt": "lab runon run", "deliver": "local"})
    job_id = (created.get("job") or created).get("id")
    report(bool(job_id), "a job to run", json.dumps(created)[:200])

    # ---- the Dashboard sets it
    rest(opener, "PUT", f"/api/cron/jobs/{job_id}?profile=default", {"updates": {"model": "beta", "provider": PROVIDER}})
    stored = job(opener, job_id)
    report((stored.get("model"), stored.get("provider")) == ("beta", PROVIDER), "the Dashboard's job update sets its model",
           json.dumps({k: stored.get(k) for k in ("model", "provider")}))
    models = await run_on(opener, job_id)
    report(bool(models) and set(models) == {"beta"}, "and its run is on that model, not the main one", json.dumps(models))

    # ---- the Hermes API, by the mark
    rest(opener, "PUT", f"/api/cron/jobs/{job_id}?profile=default", {"updates": {"model": "", "provider": ""}})
    status, body = api("PATCH", f"/api/jobs/{job_id}", {"name": f"[redde-notify] Lab runon [redde-model:beta|{PROVIDER}]"})
    report(status in (200, 201), "the Hermes API takes the mark in the job's name", f"{status} {body[:200]}")
    end, stored = time.time() + 90, {}
    while time.time() < end:
        stored = job(opener, job_id)
        if "[redde-model:" not in str(stored.get("name")):
            break
        await asyncio.sleep(3)
    report(stored.get("name") == "[redde-notify] Lab runon" and (stored.get("model"), stored.get("provider")) == ("beta", PROVIDER),
           "the plugin gives the job that model and takes the mark off",
           json.dumps({k: stored.get(k) for k in ("name", "model", "provider")}))
    models = await run_on(opener, job_id)
    report(bool(models) and set(models) == {"beta"}, "and its run is on it", json.dumps(models))

    # ---- back to the main model at once, over the Dashboard
    said = (await dash.call("command.dispatch", {"name": "redde-push", "arg": f"job-model default {job_id} - -"})).get("output", "")
    stored = job(opener, job_id)
    report(said == f"redde-push job-model set {job_id} -" and not stored.get("model"),
           "/redde-push job-model puts it back on the main model", f"{said} / {stored.get('model')!r}")
    models = await run_on(opener, job_id)
    report(bool(models) and set(models) == {"alpha"}, "and its run is on the main model again", json.dumps(models))
    rest(opener, "DELETE", f"/api/cron/jobs/{job_id}?profile=default")


asyncio.run(main())
raise SystemExit(1 if check.failures else 0)
