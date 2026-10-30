#!/usr/bin/env python3
"""A stand-in for the parts of the Cloudflare API that nofixedaddress uses.

tests/e2e.sh runs the updater against this so the whole startup and update
path can be exercised offline, without a real token. Responses use
Cloudflare's JSON envelope and error codes, and writes are validated the way
the real API validates them, so a malformed request fails here too.

Besides the API under /client/v4 it serves:

  GET  /trace                         an ip= line, like 1.1.1.1/cdn-cgi/trace
  GET  /_mock/state                   one line per record, then the write count
  POST /_mock/ip?value=ADDR           change the address /trace reports
  POST /_mock/delete?type=T&name=N    delete a record behind the updater's back
  POST /_mock/fail?count=N&status=S   answer the next N API calls with status S
"""

import argparse
import ipaddress
import json
import os
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

API_PREFIX = "/client/v4/"
WRITABLE_FIELDS = {"type", "name", "content", "proxied", "ttl", "comment"}


class State:
    def __init__(self, token, account_token, zone, ip):
        self.lock = threading.Lock()
        self.token = token
        self.account_token = account_token
        self.account = {"id": uuid.uuid4().hex, "name": "Example account"}
        self.zone = {"id": uuid.uuid4().hex, "name": zone, "status": "active", "account": self.account}
        self.records = {}
        self.ip = ip
        self.writes = 0
        self.failures = []

    def add(self, rtype, name, content, proxied=False, ttl=1, comment=None):
        rid = uuid.uuid4().hex
        self.records[rid] = {
            "id": rid,
            "zone_id": self.zone["id"],
            "zone_name": self.zone["name"],
            "name": name,
            "type": rtype,
            "content": content,
            "proxiable": True,
            "proxied": proxied,
            # Cloudflare forces automatic TTL on proxied records.
            "ttl": 1 if proxied else ttl,
            "comment": comment,
        }
        return self.records[rid]


class ApiError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def validate_record(record):
    """Raises ApiError for anything the real API would refuse."""
    rtype = record.get("type")
    if rtype not in ("A", "AAAA"):
        raise ApiError(400, 9000, f"DNS record type {rtype!r} is not supported here.")
    if not isinstance(record.get("content"), str):
        raise ApiError(400, 9005, f"Content for {rtype} record is invalid.")
    try:
        address = ipaddress.ip_address(record["content"])
    except ValueError:
        raise ApiError(400, 9005, f"Content for {rtype} record is invalid.") from None
    if address.version != (4 if rtype == "A" else 6):
        raise ApiError(400, 9005, f"Content for {rtype} record is invalid.")
    if not isinstance(record.get("proxied"), bool):
        raise ApiError(400, 9003, "Invalid 'proxied' value, must be a boolean.")
    ttl = record.get("ttl")
    if not isinstance(ttl, int) or isinstance(ttl, bool) or not (ttl == 1 or 60 <= ttl <= 86400):
        raise ApiError(400, 9021, "Invalid TTL. Must be between 60 and 86400 seconds, or 1 for Automatic.")


class Handler(BaseHTTPRequestHandler):
    state = None

    def log_message(self, format, *args):  # noqa: A002 - signature from the base class
        pass

    def send_body(self, status, body, content_type):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def ok(self, result, status=200, info=None):
        payload = {"success": True, "errors": [], "messages": [], "result": result}
        if info is not None:
            payload["result_info"] = info
        self.send_body(status, json.dumps(payload), "application/json")

    def fail(self, status, code, message):
        payload = {
            "success": False,
            "errors": [{"code": code, "message": message}],
            "messages": [],
            "result": None,
        }
        self.send_body(status, json.dumps(payload), "application/json")

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"null")
        except ValueError:
            raise ApiError(400, 6007, "Malformed JSON in request body.") from None
        if not isinstance(body, dict):
            raise ApiError(400, 6007, "Malformed JSON in request body.")
        return body

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PATCH(self):
        self.route("PATCH")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        url = urlsplit(self.path)
        query = {k: v[-1] for k, v in parse_qs(url.query, keep_blank_values=True).items()}
        with self.state.lock:
            try:
                if url.path == "/trace" and method == "GET":
                    self.send_body(200, f"fl=1f1\nh=mock\nip={self.state.ip}\nts=0\nhttp=http/1.1\n", "text/plain")
                elif url.path.startswith("/_mock/"):
                    self.control(method, url.path[len("/_mock/"):], query)
                elif url.path.startswith(API_PREFIX):
                    self.api(method, url.path[len(API_PREFIX):].strip("/").split("/"), query)
                else:
                    self.fail(404, 7000, "No route for that URI")
            except ApiError as e:
                self.fail(e.status, e.code, e.message)

    def control(self, method, action, query):
        st = self.state
        if method == "GET" and action == "state":
            lines = [
                f"{r['type']} {r['name']} {r['content']} proxied={str(r['proxied']).lower()} ttl={r['ttl']}"
                for r in sorted(st.records.values(), key=lambda r: (r["name"], r["type"]))
            ]
            lines.append(f"writes {st.writes}")
            self.send_body(200, "\n".join(lines) + "\n", "text/plain")
        elif method == "POST" and action == "ip":
            st.ip = query["value"]
            self.send_body(200, "ok\n", "text/plain")
        elif method == "POST" and action == "delete":
            doomed = [rid for rid, r in st.records.items() if r["type"] == query["type"] and r["name"] == query["name"]]
            for rid in doomed:
                del st.records[rid]
            self.send_body(200, f"deleted {len(doomed)}\n", "text/plain")
        elif method == "POST" and action == "fail":
            st.failures.extend([int(query.get("status", "503"))] * int(query.get("count", "1")))
            self.send_body(200, "ok\n", "text/plain")
        else:
            self.send_body(404, "unknown control endpoint\n", "text/plain")

    def api(self, method, parts, query):
        st = self.state
        if st.failures:
            status = st.failures.pop(0)
            raise ApiError(status, 10000 + status, f"Simulated failure with HTTP {status}")
        auth = self.headers.get("Authorization")
        user_token = auth == f"Bearer {st.token}"
        account_token = st.account_token is not None and auth == f"Bearer {st.account_token}"

        # Like the real API, each verify endpoint accepts only its own kind of
        # token and answers 401 for anything else, valid or not.
        if parts == ["user", "tokens", "verify"] and method == "GET":
            if not user_token:
                raise ApiError(401, 1000, "Invalid API Token")
            return self.ok({"id": "0" * 32, "status": "active"})
        if parts[:1] == ["accounts"] and parts[2:] == ["tokens", "verify"] and method == "GET":
            if not account_token:
                raise ApiError(401, 1000, "Invalid API Token")
            if parts[1] != st.account["id"]:
                raise ApiError(404, 7003, f"Could not route to /accounts/{parts[1]}, perhaps your object identifier is invalid?")
            return self.ok({"id": "1" * 32, "status": "active"})
        if not (user_token or account_token):
            raise ApiError(403, 10000, "Authentication error")

        if parts == ["zones"] and method == "GET":
            zones = [st.zone] if query.get("name", st.zone["name"]) == st.zone["name"] else []
            return self.ok(zones, info={"page": 1, "per_page": 20, "count": len(zones), "total_count": len(zones)})

        if len(parts) < 3 or parts[0] != "zones" or parts[2] != "dns_records" or len(parts) > 4:
            raise ApiError(404, 7000, "No route for that URI")
        if parts[1] != st.zone["id"]:
            raise ApiError(404, 7003, f"Could not route to /zones/{parts[1]}, perhaps your object identifier is invalid?")

        if len(parts) == 3:
            if method == "GET":
                found = [
                    r for r in st.records.values()
                    if query.get("type", r["type"]) == r["type"] and query.get("name", r["name"]) == r["name"]
                ]
                return self.ok(found, info={"page": 1, "per_page": 100, "count": len(found), "total_count": len(found)})
            if method == "POST":
                body = self.read_json()
                unknown = set(body) - WRITABLE_FIELDS
                if unknown:
                    raise ApiError(400, 9000, f"Unexpected fields: {sorted(unknown)}")
                candidate = {"proxied": False, "ttl": 1, **body}
                validate_record(candidate)
                name = candidate.get("name", "")
                if name != st.zone["name"] and not name.endswith("." + st.zone["name"]):
                    raise ApiError(400, 9007, "Name is not within the zone.")
                st.writes += 1
                record = st.add(candidate["type"], name, candidate["content"], candidate["proxied"],
                                candidate["ttl"], candidate.get("comment"))
                return self.ok(record)
            raise ApiError(405, 10405, "Method not allowed")

        record = st.records.get(parts[3])
        if record is None:
            raise ApiError(404, 81044, "Record does not exist.")
        if method == "GET":
            return self.ok(record)
        if method == "PATCH":
            body = self.read_json()
            unknown = set(body) - WRITABLE_FIELDS
            if unknown:
                raise ApiError(400, 9000, f"Unexpected fields: {sorted(unknown)}")
            candidate = {**record, **body}
            validate_record(candidate)
            if candidate["proxied"]:
                candidate["ttl"] = 1
            st.writes += 1
            record.update(candidate)
            return self.ok(record)
        if method == "DELETE":
            st.writes += 1
            del st.records[record["id"]]
            return self.ok({"id": record["id"]})
        raise ApiError(405, 10405, "Method not allowed")


def main():
    parser = argparse.ArgumentParser(description="Mock of the Cloudflare API for nofixedaddress tests.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0, help="0 picks a free port")
    parser.add_argument("--port-file", help="write the port here once the server is listening")
    parser.add_argument("--token", required=True, help="a user API token to accept")
    parser.add_argument("--account-token", help="an account-owned API token to accept")
    parser.add_argument("--zone", default="example.com")
    parser.add_argument("--ip", default="5.6.7.8", help="address reported by /trace")
    parser.add_argument("--record", action="append", default=[], metavar="TYPE:NAME:CONTENT[:proxied]",
                        help="seed a record; may be repeated")
    args = parser.parse_args()

    state = State(args.token, args.account_token, args.zone, args.ip)
    for spec in args.record:
        rtype, name, content = spec.split(":", 2)
        proxied = content.endswith(":proxied")
        if proxied:
            content = content[: -len(":proxied")]
        state.add(rtype, name, content, proxied=proxied, ttl=300)

    Handler.state = state
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    if args.port_file:
        # Written then renamed, so a reader never sees a partial port number.
        with open(args.port_file + ".tmp", "w") as f:
            f.write(str(server.server_address[1]))
        os.replace(args.port_file + ".tmp", args.port_file)
    server.serve_forever()


if __name__ == "__main__":
    main()
