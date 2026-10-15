# A Kubernetes API that knows one pod, app-0 of namespace tenant-a at
# POD_IP: lists answer it, watches stay open and say nothing.
import json, os, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

POD = {"apiVersion": "v1", "kind": "Pod",
       "metadata": {"name": "app-0", "namespace": "tenant-a", "uid": "0b5a1c2e-0000-4000-8000-000000000001", "resourceVersion": "1"},
       "spec": {"nodeName": "node-1", "containers": [{"name": "app", "image": "app"}]},
       "status": {"phase": "Running", "podIP": os.environ["POD_IP"], "podIPs": [{"ip": os.environ["POD_IP"]}]}}
NAMESPACE = {"apiVersion": "v1", "kind": "Namespace",
             "metadata": {"name": "tenant-a", "uid": "0b5a1c2e-0000-4000-8000-000000000002", "resourceVersion": "1"}}


class API(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if "watch=true" in query or "watch=1" in query:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            time.sleep(600)
            return
        kind, items = {"/api/v1/pods": ("PodList", [POD]), "/api/v1/namespaces": ("NamespaceList", [NAMESPACE]),
                       "/api/v1/nodes": ("NodeList", []), "/apis/apps/v1/replicasets": ("ReplicaSetList", [])}.get(path, (None, None))
        if kind is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = json.dumps({"apiVersion": "v1", "kind": kind, "metadata": {"resourceVersion": "1"}, "items": items}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("0.0.0.0", 8080), API).serve_forever()
