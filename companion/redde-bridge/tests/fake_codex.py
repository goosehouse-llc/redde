"""A stand-in for `codex app-server`: answers initialize and account/rateLimits/read over stdio
with an answer shaped like Codex 0.167's (a free plan's, account id made up).

FAKE_CODEX=fail answers the read with an error; FAKE_CODEX=hang never answers it.
"""
import json
import os
import sys
import time

ANSWER = {
    "ordinaryUsageAllowed": True,
    "rateLimits": {"limitId": "codex", "limitName": None, "normalModelSlug": None,
                   "primary": {"usedPercent": 1, "windowDurationMins": 43200, "resetsAt": 1797127191},
                   "secondary": None, "credits": {"hasCredits": False, "unlimited": False, "balance": None},
                   "individualLimit": None, "spendControlReached": False, "planType": "free", "rateLimitReachedType": None},
    "rateLimitsByLimitId": {"codex": {"limitId": "codex", "limitName": None, "normalModelSlug": None,
                                      "primary": {"usedPercent": 1, "windowDurationMins": 43200, "resetsAt": 1797127191},
                                      "secondary": None, "credits": {"hasCredits": False, "unlimited": False, "balance": None},
                                      "individualLimit": None, "spendControlReached": False, "planType": "free",
                                      "rateLimitReachedType": None}},
    "rateLimitResetCredits": {"availableCount": 0, "credits": None},
    "accountId": "account-123",
    "rateLimitUpsell": None,
}

for line in sys.stdin:
    message = json.loads(line)
    method, rid = message.get("method"), message.get("id")
    if method == "initialize":
        reply = {"id": rid, "result": {"userAgent": "fake", "platformFamily": "unix", "platformOs": "macos"}}
    elif method == "account/rateLimits/read":
        mode = os.environ.get("FAKE_CODEX")
        if mode == "hang":
            time.sleep(60)
        reply = {"id": rid, "error": {"code": -32600, "message": "not signed in"}} if mode == "fail" else {"id": rid, "result": ANSWER}
    else:
        continue
    # Codex sends notifications of its own between answers.
    sys.stdout.write(json.dumps({"method": "remoteControl/status/changed", "params": {}}) + "\n")
    sys.stdout.write(json.dumps(reply) + "\n")
    sys.stdout.flush()
