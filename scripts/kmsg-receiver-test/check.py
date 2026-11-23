# check.py LOGS: the file exporter's output holds both lines, each with the
# line as body, talos-time as its time and service.name talos-kmsg.
import json, sys
sys.path.insert(0, "/t")
import lines

records = []
for raw in open(sys.argv[1]):
    for rl in json.loads(raw)["resourceLogs"]:
        res = {a["key"]: a["value"]["stringValue"] for a in rl["resource"]["attributes"]}
        for sl in rl["scopeLogs"]:
            for r in sl["logRecords"]:
                records.append((res, r))
assert len(records) == len(lines.LINES), "want %d records, got %d" % (len(lines.LINES), len(records))
records.sort(key=lambda x: int(x[1]["timeUnixNano"]))
for (res, r), want, ns in zip(records, lines.LINES, lines.EXPECTED_NS):
    assert res.get("service.name") == "talos-kmsg", res
    assert r["body"]["stringValue"] == want["msg"], r["body"]
    assert int(r["timeUnixNano"]) == ns, (r["timeUnixNano"], ns)
    attrs = {a["key"]: a["value"] for a in r["attributes"]}
    assert attrs["facility"]["stringValue"] == want["facility"], attrs
    assert "msg" not in attrs, attrs
print("PASS both lines arrive with the line as body, talos-time as time and service.name talos-kmsg")
