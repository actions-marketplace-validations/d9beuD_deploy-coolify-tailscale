#!/usr/bin/env python3
"""Minimal fake Coolify API used to test scripts/deploy.sh.

Usage: mock_coolify.py PORT

Behaviour is driven by the resource UUID passed to /api/v1/deploy:
  app-ok        -> deployment goes queued -> in_progress -> finished
  app-fail      -> deployment goes queued -> in_progress -> failed (with logs)
  app-slow      -> deployment stays in_progress forever
  service-ok    -> service started, no deployment to follow
  unauthorized  -> 200 response carrying an "Unauthorized" message
  missing       -> 404 "No resources found."
Tag "web" deploys app-ok through the tag endpoint.
Any request without "Authorization: Bearer test-token" gets a 401.
Set MOCK_GET_ONLY=1 to emulate an old Coolify that only accepts GET /deploy.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

GET_ONLY = os.environ.get("MOCK_GET_ONLY") == "1"
DEPLOYMENTS = {}  # deployment uuid -> {"kind": ..., "polls": int}
PLANS = {
    "app-ok": ["queued", "in_progress", "finished"],
    "app-fail": ["queued", "in_progress", "failed"],
    "app-slow": ["in_progress"],
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("mock: " + (fmt % args) + "\n")

    def send_json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        return self.headers.get("Authorization") == "Bearer test-token"

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def route(self, method):
        url = urlparse(self.path)
        # Like Laravel, keep the last value of a repeated parameter.
        query = {k: v[-1] for k, v in parse_qs(url.query).items()}
        path = url.path

        if path in ("/api/health", "/api/v1/health"):
            body = b"OK"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if not self.authorized():
            return self.send_json(401, {"message": "Unauthenticated."})

        if path == "/api/v1/deploy":
            wanted = "GET" if GET_ONLY else "POST"
            if method != wanted:
                return self.send_json(405, {"message": "This endpoint has changed to a POST request."})
            return self.deploy(query)

        if path.startswith("/api/v1/deployments/") and method == "GET":
            uuid = path.rsplit("/", 1)[-1]
            dep = DEPLOYMENTS.get(uuid)
            if dep is None:
                return self.send_json(404, {"message": "Deployment not found."})
            plan = PLANS[dep["kind"]]
            status = plan[min(dep["polls"], len(plan) - 1)]
            dep["polls"] += 1
            logs = json.dumps([
                {"output": f"Building {dep['kind']}...", "hidden": False},
                {"output": "secret internal command", "hidden": True},
                {"output": "Build failed: exit code 1" if status == "failed" else "Step done", "hidden": False},
            ])
            return self.send_json(200, {
                "deployment_uuid": uuid,
                "status": status,
                "application_name": dep["kind"],
                "deployment_url": f"/project/p/environment/e/application/{dep['kind']}/deployment/{uuid}",
                "logs": logs,
            })

        self.send_json(404, {"message": "Not found."})

    def deploy(self, query):
        if query.get("tag"):
            if query["tag"] != "web":
                return self.send_json(404, {"message": "No resources found with this tag."})
            dep_uuid = f"dep-tag-{len(DEPLOYMENTS)}"
            DEPLOYMENTS[dep_uuid] = {"kind": "app-ok", "polls": 0}
            return self.send_json(200, {
                "message": ["Application app-ok deployment queued."],
                "details": [{"resource_uuid": "app-ok", "deployment_uuid": dep_uuid}],
            })

        deployments = []
        for uuid in filter(None, query.get("uuid", "").split(",")):
            if uuid in PLANS:
                dep_uuid = f"dep-{uuid}-{len(DEPLOYMENTS)}"
                DEPLOYMENTS[dep_uuid] = {"kind": uuid, "polls": 0}
                deployments.append({"message": f"Application {uuid} deployment queued.",
                                    "resource_uuid": uuid, "deployment_uuid": dep_uuid})
            elif uuid == "service-ok":
                deployments.append({"message": "Service service-ok started. It could take a while, be patient.",
                                    "resource_uuid": uuid})
            elif uuid == "unauthorized":
                deployments.append({"message": "Unauthorized to deploy this application.",
                                    "resource_uuid": uuid})
        if not deployments:
            return self.send_json(404, {"message": "No resources found."})
        self.send_json(200, {"deployments": deployments})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
