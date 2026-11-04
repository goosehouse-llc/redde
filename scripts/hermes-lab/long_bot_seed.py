"""Seeds the lab's main profile with a long "Bot Chat" (PR 48, issue 47): 1,200 messages, numbered,
so the app's paged open of a long bot chat can be checked against a real host. Run with the lab
Hermes's own Python, from its source folder, with HERMES_HOME set (lab.sh longbot does).

    python long_bot_seed.py [count]
"""
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.getcwd())
from hermes_state import SessionDB  # noqa: E402

count = int(sys.argv[1]) if len(sys.argv) > 1 else 1200
db = SessionDB(db_path=Path(os.environ["HERMES_HOME"]) / "state.db")
sid = "longbotchat"
db.create_session(sid, "tui")
start = time.time() - count * 30
for n in range(1, count + 1):
    role = "user" if n % 2 else "assistant"
    db.append_message(sid, role, f"long message {n}", timestamp=start + n * 30)
with db._lock:
    db._conn.execute("UPDATE sessions SET title = ? WHERE id = ?", ("Bot Chat", sid))
db.set_session_hidden(sid, True)
db.close()
print(f"seeded {sid} with {count} messages")
