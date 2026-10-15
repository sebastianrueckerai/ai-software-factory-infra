#!/bin/sh
# Every image the cluster runs and every chart Flux installs comes from the
# factory's store (roadmap 203), pinned by a line of the code repository's
# upstream-images.txt: an image by its copy, git.aisoftwarefactory.world/
# upstream/<the line>, or at its upstream by digest when the line is
# marked bootstrap (Forgejo's path, which the store cannot serve); a chart
# by an OCIRepository of the store at its digest or by the store's Helm
# repository at an exact version; a project template's bases by their
# copies; a bootstrap line's registry through the nodes' mirror of the
# store (talos/patches.yaml); the runbook's hand installs by a line's
# digest. And every credential comes from a Secret, never from the tree or
# a chart's default: no container env named like one and no ClickHouse
# user's password holds a literal in a manifest, a HelmRelease's values or
# a chart's render, where a HelmRelease's valuesFrom renders as
# valuesFrom-Secret. Builds k8s/platform and Flux's components
# with kubectl kustomize and renders every HelmRelease's chart with helm,
# from the repository root:
#   sh scripts/upstream-images-test/test.sh [upstream-images.txt]
# Given the list, it checks every reference against it and renders the
# charts from their upstreams as the list pins them. Without one
# (config-check) it checks every copy and chart is in the store, read with
# REGISTRY_USER and REGISTRY_PASSWORD, and renders the charts from there.
list=${1:-}
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
kubectl kustomize k8s/platform > "$tmp/platform.yaml" || { echo "FAIL kustomize k8s/platform"; exit 1; }
kubectl kustomize clusters/sf/flux-system > "$tmp/flux.yaml" || { echo "FAIL kustomize clusters/sf/flux-system"; exit 1; }
python3 - "$tmp" "$list" <<'PY'
import base64, glob, hashlib, json, os, re, subprocess, sys, urllib.request, yaml
tmp, listfile = sys.argv[1], sys.argv[2]
host = "git.aisoftwarefactory.world"
store = host + "/upstream/"
helmrepo = "https://%s/api/packages/upstream/helm" % host
fails = []
def check(ok, what):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        fails.append(what)
copies, boot, files, archives = set(), {}, {}, {}
if listfile:
    for line in open(listfile):
        f = line.split()
        if not f or f[0].startswith("#"):
            continue
        if f[0].startswith("https://"):
            url, hexd = f[0].rsplit("@sha256:", 1)
            name = url.rsplit("/", 1)[1]
            (archives if f[1] == "helm" else files)[name] = (url, hexd)
        elif f[1:] == ["bootstrap"]:
            image, digest = f[0].split("@")
            name, tag = image.rsplit(":", 1)
            boot[(name, digest)] = tag
        else:
            copies.add(f[0])
else:
    login = base64.b64encode(("%s:%s" % (os.environ["REGISTRY_USER"], os.environ["REGISTRY_PASSWORD"])).encode()).decode()
def in_store(path, ref):
    req = urllib.request.Request("https://%s/v2/upstream/%s/manifests/%s" % (host, path, ref), method="HEAD", headers={
        "Authorization": "Basic " + login,
        "Accept": "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, "
                  "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"})
    try:
        return urllib.request.urlopen(req, timeout=30).status == 200
    except Exception:
        return False
def pinned(img):
    m = re.fullmatch(r"(?:docker\.io/)?([^@]+?)(?::([^:/@]+))?@(sha256:[0-9a-f]{64})", img or "")
    if not m:
        return False
    name, tag, digest = m.group(1), m.group(2), m.group(3)
    if img.startswith(store):
        path = name[len(store):]
        if path.startswith("files/"):
            if not listfile:
                return in_store(path, digest)
            f = files.get(path[len("files/"):])
            return f is not None and tag == f[1][:12]
        return in_store(path, digest) if not listfile else img[len(store):] in copies
    if "." not in name.split("/")[0]:
        name = "docker.io/" + name
    if not listfile:
        return True
    want = boot.get((name, digest))
    return want is not None and tag in (None, want)
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
FROM_SECRET = "valuesFrom-Secret"
literal = []
def credentials(o, where):
    if isinstance(o, dict):
        if (re.search(r"(PASSWORD|SECRET|TOKEN|_KEY)$", str(o.get("name"))) and isinstance(o.get("value"), str)
                and o["value"] not in ("", FROM_SECRET)):
            literal.append("%s env %s" % (where, o["name"]))
        for k, v in o.items():
            if re.search(r"(^|/)password$", str(k)) and isinstance(v, str) and v not in ("", FROM_SECRET):
                literal.append("%s %s" % (where, k))
            credentials(v, where)
    elif isinstance(o, list):
        for v in o:
            credentials(v, where)
def scan(docs):
    for d in docs:
        if not isinstance(d, dict):
            continue
        meta = d.get("metadata") or {}
        where = "%s/%s" % (d.get("kind"), meta.get("name"))
        if d.get("kind") == "HelmRelease":
            credentials((d.get("spec") or {}).get("values"), where + " values")
            continue
        if d.get("kind") != "Secret":
            credentials(d.get("spec"), where)
        if "test" in str((meta.get("annotations") or {}).get("helm.sh/hook", "")):
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
helm_env = dict(os.environ, HELM_REGISTRY_CONFIG=os.path.join(tmp, "registry.json"), HELM_REPOSITORY_CACHE=os.path.join(tmp, "cache"))
if not listfile:
    subprocess.run(["helm", "registry", "login", host, "-u", os.environ["REGISTRY_USER"], "--password-stdin"],
                   input=os.environ["REGISTRY_PASSWORD"], text=True, env=helm_env, check=True, capture_output=True)
def chart_of(name, spec):
    """the helm arguments of the HelmRelease's chart, checked to come from the store"""
    if "chartRef" in spec:
        src = sources[(spec["chartRef"]["kind"], spec["chartRef"]["name"])]
        digest = (src.get("ref") or {}).get("digest", "")
        url = src["url"]
        check(url.startswith("oci://" + store) and re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is not None
              and src.get("secretRef", {}).get("name") == "forgejo-registry",
              "HelmRelease/%s chart: %s@%s, the store's copy by digest" % (name, url, digest))
        path = url[len("oci://" + store):]
        if listfile:
            check(any(c.startswith(path + ":") and c.endswith("@" + digest) for c in copies),
                  "HelmRelease/%s chart: %s@%s is a line" % (name, path, digest))
            return ["oci://%s@%s" % (path, digest)]
        return ["%s@%s" % (url, digest)]
    cs = spec["chart"]["spec"]
    if cs["sourceRef"]["kind"] == "GitRepository":
        return [cs["chart"]]
    src = sources[("HelmRepository", cs["sourceRef"]["name"])]
    archive = "%s-%s.tgz" % (cs["chart"], cs["version"])
    check(src["url"] == helmrepo and re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+", cs["version"]) is not None
          and src.get("secretRef", {}).get("name") == "forgejo-charts",
          "HelmRelease/%s chart: %s from %s, the store's Helm repository at an exact version" % (name, archive, src["url"]))
    if listfile:
        a = archives.get(archive)
        check(a is not None, "HelmRelease/%s chart: %s is a line" % (name, archive))
        if a is None:
            return None
        req = urllib.request.Request(a[0])
    else:
        req = urllib.request.Request(helmrepo + "/" + archive, headers={"Authorization": "Basic " + login})
    try:
        data = urllib.request.urlopen(req, timeout=120).read()
    except Exception as e:
        check(False, "HelmRelease/%s chart: %s from %s: %s" % (name, archive, req.full_url, e))
        return None
    if listfile:
        check(hashlib.sha256(data).hexdigest() == a[1], "HelmRelease/%s chart: %s matches its sha256" % (name, archive))
    path = os.path.join(tmp, archive)
    open(path, "wb").write(data)
    return [path]
for i, hr in enumerate(d for d in docs if d.get("kind") == "HelmRelease"):
    spec, name = hr["spec"], hr["metadata"]["name"]
    chart = chart_of(name, spec)
    if chart is None:
        continue
    vals = os.path.join(tmp, "values-%d.yaml" % i)
    with open(vals, "w") as f:
        yaml.safe_dump(spec.get("values") or {}, f)
    ns = spec.get("targetNamespace", hr["metadata"]["namespace"])
    secret = [a for ref in spec.get("valuesFrom") or [] if ref.get("targetPath")
              for a in ("--set-string", "%s=%s" % (ref["targetPath"], FROM_SECRET))]
    r = subprocess.run(["helm", "template", spec.get("releaseName", name)] + chart + ["-n", ns, "-f", vals] + secret,
                       capture_output=True, text=True, env=helm_env)
    if r.returncode:
        check(False, "HelmRelease %s renders: %s" % (name, r.stderr.strip()[-300:]))
        continue
    scan(yaml.safe_load_all(r.stdout))
    labels = ((((spec.get("values") or {}).get("runner") or {}).get("config") or {}).get("file") or {}).get("runner", {}).get("labels") or []
    for l in labels:
        if "docker://" in l:
            found.append(("HelmRelease/%s job image %s" % (name, l.split(":", 1)[0]), l.split("docker://", 1)[1]))
for df in sorted(glob.glob("factory/templates/*/Dockerfile")):
    upstream = None
    for line in open(df):
        if line.startswith("ARG UPSTREAM="):
            upstream = line.split("=", 1)[1].strip()
        m = re.match(r"FROM\s+(\S+)", line)
        if m and m.group(1) != "scratch":
            found.append((df, m.group(1).replace("${UPSTREAM}", upstream or "${UPSTREAM}")))
for where, img in sorted(set(found)):
    check(pinned(img), "%s: %s, the store's copy of a line or a bootstrap line by its digest" % (where, img))
if listfile:
    listed = open(listfile).read()
    for dg in sorted(set(re.findall(r"sha256:[0-9a-f]{64}", open("docs/reseed-runbook.md").read()))):
        check(dg in listed, "docs/reseed-runbook.md: %s, a line's digest" % dg)
mirrors = {d["name"]: d["endpoints"] for d in yaml.safe_load_all(open("talos/patches.yaml"))
           if d and d.get("kind") == "RegistryMirrorConfig"}
for reg in sorted({name.split("/")[0] for name, _ in boot}):
    check(mirrors.get(reg) == [{"url": "https://%s/v2/upstream/%s" % (host, reg), "overridePath": True}],
          "talos/patches.yaml: the nodes pull %s through the store's mirror" % reg)
check(not literal, "no manifest, HelmRelease value or chart render holds a literal credential" +
      "".join("\n  " + w for w in literal))
print("%d images, %d failed" % (len(set(found)), len(fails)))
sys.exit(1 if fails else 0)
PY
