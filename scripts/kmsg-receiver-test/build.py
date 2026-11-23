# build.py VALUES CONFIG: the test's collector config from the agent's values
# (otelAgent as JSON): the receiver the logs pipeline takes, as the values
# write it, and a file exporter in place of the OTLP one.
import json, sys

v = json.load(open(sys.argv[1]))
assert v["ports"].get("kmsg") == {"enabled": True, "containerPort": 5170, "servicePort": 5170, "hostPort": 5170, "protocol": "TCP"}, v["ports"]
rx = v["config"]["receivers"].get("tcplog/kmsg")
assert rx, "no receiver tcplog/kmsg in otelAgent.config.receivers"
assert rx["listen_address"] == "0.0.0.0:5170", rx
assert "tcplog/kmsg" in v["config"]["service"]["pipelines"]["logs"]["receivers"], "logs pipeline does not take tcplog/kmsg"
json.dump({"receivers": {"tcplog/kmsg": rx}, "exporters": {"file": {"path": "/out/logs.json"}},
           "service": {"pipelines": {"logs": {"receivers": ["tcplog/kmsg"], "exporters": ["file"]}}}}, open(sys.argv[2], "w"))
