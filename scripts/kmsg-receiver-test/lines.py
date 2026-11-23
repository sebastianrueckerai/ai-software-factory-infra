# The two lines of the test, as Talos's JSON-lines sender writes them
# (internal/app/machined/pkg/runtime/logging/sender_jsonlines.go).
import json

LINES = [
    {"msg": '[talos] Sending SIGKILL to cgroup {"component": "controller-runtime", "controller": "runtime.OOMController", '
            '"cgroup": "/sys/fs/cgroup/kubepods/burstable/pod91adbc7d-6406-4a24-ac91-c1979b028d36"}\n',
     "facility": "user", "priority": "warning", "seq": 711, "clock": 6252819000,
     "talos-time": "2026-11-18T12:06:01.3258698Z", "talos-level": "warn"},
    {"msg": "oom-kill:constraint=CONSTRAINT_MEMCG,nodemask=(null),cpuset=cri-containerd-0a1b.scope,mems_allowed=0,"
            "oom_memcg=/kubepods/burstable/pod91adbc7d-6406-4a24-ac91-c1979b028d36/0a1b,"
            "task_memcg=/kubepods/burstable/pod91adbc7d-6406-4a24-ac91-c1979b028d36/0a1b,task=java,pid=4242,uid=1000",
     "facility": "kern", "priority": "info", "seq": 712, "clock": 6252820500,
     "talos-time": "2026-11-18T12:06:02.5Z", "talos-level": "info"},
]
# talos-time as nanoseconds since the epoch, derived by hand:
# 2026-11-18T12:06:01Z = 1795003561 s (20775 days from 1970 to 2026-11-18 at 86400 s, plus 12:06:01)
EXPECTED_NS = [1795003561325869800, 1795003562500000000]


def lines():
    return [json.dumps(x) + "\n" for x in LINES]
