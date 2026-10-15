#!/bin/sh
# Every image the cluster runs is pinned by a line of the code repository's
# upstream-images.txt (roadmap 203): the factory's store's copy,
# git.aisoftwarefactory.world/upstream/<the line>, or the line at its
# upstream when it is marked bootstrap (Forgejo's path, which the store
# cannot serve). Builds k8s/platform and Flux's components with kubectl
# kustomize and renders every HelmRelease's chart with helm (it fetches
# the charts), from the repository root:
#   sh scripts/upstream-images-test/test.sh [upstream-images.txt]
list=${1:-../ai-software-factory-code/upstream-images.txt}
[ -f "$list" ] || { echo "FAIL no list at $list"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
kubectl kustomize k8s/platform > "$tmp/platform.yaml" || { echo "FAIL kustomize k8s/platform"; exit 1; }
kubectl kustomize clusters/sf/flux-system > "$tmp/flux.yaml" || { echo "FAIL kustomize clusters/sf/flux-system"; exit 1; }
python3 - "$list" "$tmp" <<'PY'
import base64, os, re, subprocess, sys, yaml
listfile, tmp = sys.argv[1], sys.argv[2]
store = "git.aisoftwarefactory.world/upstream/"
copies, boot = set(), {}
for line in open(listfile):
    f = line.split()
    if not f or f[0].startswith("#"):
        continue
    if f[1:] == ["bootstrap"]:
        image, digest = f[0].split("@")
        name, tag = image.rsplit(":", 1)
        boot[(name, digest)] = tag
    else:
        copies.add(f[0])
def pinned(img):
    if img.startswith(store):
        return img[len(store):] in copies
    m = re.fullmatch(r"(?:docker\.io/)?([^@]+?)(?::([^:/@]+))?@(sha256:[0-9a-f]{64})", img)
    if not m:
        return False
    name = m.group(1) if "." in m.group(1).split("/")[0] else "docker.io/" + m.group(1)
    tag = boot.get((name, m.group(3)))
    return tag is not None and m.group(2) in (None, tag)
found = []
def pods(o, where):
    if isinstance(o, dict):
        if isinstance(o.get("containers"), list):
            for c in (o.get("initContainers") or []) + o["containers"]:
                found.append((where, c.get("image")))
                for e in c.get("env") or []:
                    if e.get("name") == "OPERATOR_IMAGE_NAME":
                        found.append((where + " OPERATOR_IMAGE_NAME", e.get("value")))
                for a in c.get("args") or []:
                    if str(a).startswith("--acme-http01-solver-image="):
                        found.append((where + " acmesolver", a.split("=", 1)[1]))
        for v in o.values():
            pods(v, where)
    elif isinstance(o, list):
        for v in o:
            pods(v, where)
def scan(docs):
    for d in docs:
        if not isinstance(d, dict):
            continue
        meta = d.get("metadata") or {}
        where = "%s/%s" % (d.get("kind"), meta.get("name"))
        if "test" in str((meta.get("annotations") or {}).get("helm.sh/hook", "")):
            continue
        if d.get("kind") == "HelmRelease":
            continue
        pods(d.get("spec"), where)
        if d.get("kind") == "Cluster" and d.get("apiVersion", "").startswith("postgresql.cnpg.io/"):
            found.append((where + " imageName", d["spec"].get("imageName", "(the operator's default)")))
        if d.get("kind") == "Secret" and "SIDECAR_IMAGE" in (d.get("data") or {}):
            found.append((where + " SIDECAR_IMAGE", base64.b64decode(d["data"]["SIDECAR_IMAGE"]).decode().strip()))
        if d.get("kind") == "ConfigMap" and "helperPod.yaml" in (d.get("data") or {}):
            pods(yaml.safe_load(d["data"]["helperPod.yaml"]), where + " helperPod")
docs = [d for f in ("platform.yaml", "flux.yaml") for d in yaml.safe_load_all(open(os.path.join(tmp, f))) if d]
scan(docs)
sources = {(d["kind"], d["metadata"]["name"]): d["spec"] for d in docs if d.get("kind") in ("HelmRepository", "OCIRepository")}
for i, hr in enumerate(d for d in docs if d.get("kind") == "HelmRelease"):
    spec, name = hr["spec"], hr["metadata"]["name"]
    if "chartRef" in spec:
        src = sources[(spec["chartRef"]["kind"], spec["chartRef"]["name"])]
        ref = src["ref"]
        chart = [src["url"], "--version", ref.get("semver") or ref.get("tag")]
    elif spec["chart"]["spec"]["sourceRef"]["kind"] == "GitRepository":
        chart = [spec["chart"]["spec"]["chart"]]
    else:
        cs = spec["chart"]["spec"]
        chart = [cs["chart"], "--repo", sources[("HelmRepository", cs["sourceRef"]["name"])]["url"], "--version", cs["version"]]
    vals = os.path.join(tmp, "values-%d.yaml" % i)
    with open(vals, "w") as f:
        yaml.safe_dump(spec.get("values") or {}, f)
    ns = spec.get("targetNamespace", hr["metadata"]["namespace"])
    r = subprocess.run(["helm", "template", spec.get("releaseName", name)] + chart + ["-n", ns, "-f", vals], capture_output=True, text=True)
    if r.returncode:
        print("FAIL HelmRelease %s renders: %s" % (name, r.stderr.strip()[-300:]))
        sys.exit(1)
    scan(yaml.safe_load_all(r.stdout))
    labels = ((((spec.get("values") or {}).get("runner") or {}).get("config") or {}).get("file") or {}).get("runner", {}).get("labels") or []
    for l in labels:
        if "docker://" in l:
            found.append(("HelmRelease/%s job image %s" % (name, l.split(":", 1)[0]), l.split("docker://", 1)[1]))
fail = 0
for where, img in sorted(set(found)):
    if pinned(img):
        print("PASS %s: %s" % (where, img))
    else:
        fail += 1
        print("FAIL %s: %s is neither the store's copy of a line of %s nor a bootstrap line by its digest" % (where, img, listfile))
print("%d images, %d failed" % (len(set(found)), fail))
sys.exit(1 if fail else 0)
PY
