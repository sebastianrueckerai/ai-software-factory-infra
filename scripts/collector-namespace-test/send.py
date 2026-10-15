# send.py URL SERVICE: one log, one gauge point and one span from service
# SERVICE, each naming namespace victim on its resource and on its record,
# in both of the forms the alert routing reads.
import json, sys, urllib.request

url, service = sys.argv[1], sys.argv[2]
named = [{"key": "k8s.namespace.name", "value": {"stringValue": "victim"}},
         {"key": "k8s_namespace_name", "value": {"stringValue": "victim"}}]
resource = {"attributes": [{"key": "service.name", "value": {"stringValue": service}}] + named}
bodies = {
    "logs": {"resourceLogs": [{"resource": resource, "scopeLogs": [{"logRecords": [
        {"timeUnixNano": "1700000000000000000", "body": {"stringValue": "hello"}, "attributes": named}]}]}]},
    "metrics": {"resourceMetrics": [{"resource": resource, "scopeMetrics": [{"metrics": [
        {"name": "up", "gauge": {"dataPoints": [{"timeUnixNano": "1700000000000000000", "asDouble": 1, "attributes": named}]}}]}]}]},
    "traces": {"resourceSpans": [{"resource": resource, "scopeSpans": [{"spans": [
        {"traceId": "5b8efff798038103d269b633813fc60c", "spanId": "eee19b7ec3c1b174", "name": "GET /",
         "kind": 2, "startTimeUnixNano": "1700000000000000000", "endTimeUnixNano": "1700000001000000000", "attributes": named}]}]}]},
}
for signal in sys.argv[3:] or bodies:
    req = urllib.request.Request(url + "/v1/" + signal, json.dumps(bodies[signal]).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as res:
        assert res.status == 200, (signal, res.status)
