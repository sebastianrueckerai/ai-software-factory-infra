# check.py APP K8S_INFRA: what the file exporters wrote, by sending service.
import json, sys

def resources(path):
    out = {}
    for line in open(path):
        for key, scopes, records in (("resourceLogs", "scopeLogs", "logRecords"),
                                     ("resourceMetrics", "scopeMetrics", None), ("resourceSpans", "scopeSpans", "spans")):
            for r in json.loads(line).get(key, []):
                attrs = {a["key"]: a["value"].get("stringValue") for a in r["resource"].get("attributes", [])}
                recs = []
                for s in r.get(scopes, []):
                    if records:
                        recs += s.get(records, [])
                    else:
                        for m in s.get("metrics", []):
                            recs += m.get("gauge", {}).get("dataPoints", [])
                rec_attrs = [{a["key"]: a["value"].get("stringValue") for a in x.get("attributes", [])} for x in recs]
                out.setdefault(attrs["service.name"], []).append((key, attrs, rec_attrs))
    return out

passed = failed = 0
def ok(name, cond):
    global passed, failed
    if cond:
        passed += 1; print("PASS", name)
    else:
        failed += 1; print("FAIL", name)

app, infra = resources(sys.argv[1]), resources(sys.argv[2])
for service, want in (("app-a", "tenant-a"), ("stranger", None)):
    got = app.get(service, [])
    ok(f"{service}: logs, metrics and traces arrived on 4318", sorted(k for k, _, _ in got) == ["resourceLogs", "resourceMetrics", "resourceSpans"])
    for key, attrs, recs in got:
        ok(f"{service} {key}: resource k8s.namespace.name is {want}, not the sent victim", attrs.get("k8s.namespace.name") == want)
        ok(f"{service} {key}: no resource k8s_namespace_name", "k8s_namespace_name" not in attrs)
        ok(f"{service} {key}: no record names a namespace", recs and all("k8s.namespace.name" not in r and "k8s_namespace_name" not in r for r in recs))
got = infra.get("k8s-infra", [])
ok("k8s-infra: its log arrived on 4319", [k for k, _, _ in got] == ["resourceLogs"])
for key, attrs, recs in got:
    ok("k8s-infra: the namespace it names stays, on resource and record",
       attrs.get("k8s.namespace.name") == "victim" and all(r.get("k8s.namespace.name") == "victim" for r in recs))
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
