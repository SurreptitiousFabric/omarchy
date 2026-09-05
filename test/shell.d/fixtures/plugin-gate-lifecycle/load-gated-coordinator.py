"""Own and reap one isolated production coordinator, without recording stdin."""

import ctypes
import json
import os
import signal
import subprocess
import sys


if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")

record_path, command = sys.argv[1:]
child = subprocess.Popen([command], start_new_session=True)
record = {"supervisorPid": os.getpid(), "coordinatorPid": child.pid, "reaped": []}


def save():
    with open(record_path, "w", encoding="utf-8") as output:
        json.dump(record, output)
        output.write("\n")


def stop(_signum, _frame):
    record["stopped"] = True
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass


signal.signal(signal.SIGTERM, stop)
save()
coordinator_status = None
while True:
    try:
        pid, status = os.waitpid(-1, 0)
    except ChildProcessError:
        break
    record["reaped"].append(pid)
    if pid == child.pid:
        coordinator_status = os.waitstatus_to_exitcode(status)

record["allChildrenReaped"] = True
record["coordinatorExit"] = coordinator_status
save()
sys.exit(coordinator_status if coordinator_status is not None and coordinator_status >= 0 else 143)
