"""Local SMH API integration tests; no real cloud account or token required."""

import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, unquote, urlsplit


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/download_directory.sh"
REMOTE = "DataSet/C-NMC"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, status, body, headers=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, data, status=200):
        self.respond(status, json.dumps(data).encode(), {"Content-Type": "application/json"})

    def do_POST(self):
        self.send_json({"libraryId": "library", "spaceId": "space", "accessToken": "test-access"})

    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path.startswith("/api/v1/directory/library/space/"):
            remote = unquote(parsed.path.split("/space/", 1)[1])
            query = parse_qs(parsed.query)
            page, limit = int(query["page"][0]), int(query["page_size"][0])
            self.server.pages.append((remote, page))
            if remote not in self.server.dirs:
                self.send_json({"message": "not found"}, 404)
                return
            items = self.server.dirs[remote]
            self.send_json({"contents": items[(page - 1) * limit:page * limit], "totalNum": len(items)})
        elif parsed.path.startswith("/api/v1/file/library/space/"):
            remote = unquote(parsed.path.split("/space/", 1)[1])
            self.server.transfers.append((remote, self.headers.get("Range")))
            data = self.server.files[remote]
            offset = int(self.headers["Range"].split("=")[1].split("-")[0]) if self.headers.get("Range") else 0
            headers = {"Content-Range": f"bytes {offset}-{len(data) - 1}/{len(data)}"} if offset else {}
            self.respond(206 if offset else 200, data[offset:], headers)
        else:
            self.send_json({"message": "unexpected path"}, 404)


class DirectoryDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.dest = Path(self.temp.name) / "download"
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.dirs = {REMOTE: []}
        self.server.files = {}
        self.server.pages = []
        self.server.transfers = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def add_file(self, parent, name, data):
        self.server.dirs[parent].append({"type": "file", "name": name, "size": str(len(data))})
        self.server.files[f"{parent}/{name}"] = data

    def run_script(self, remote=REMOTE):
        env = {**os.environ, "TBOX_BASE_URL": f"http://127.0.0.1:{self.server.server_port}",
               "TBOX_USER_TOKEN": "test-token-not-a-real-credential", "NO_PROXY": "127.0.0.1",
               "no_proxy": "127.0.0.1"}
        return subprocess.run(["bash", str(SCRIPT), remote, str(self.dest)], env=env,
                              capture_output=True, text=True, timeout=90)

    def test_recursive_pagination_names_resume_and_repeat(self):
        # More than 100 entries exercises the real page size without large downloads.
        for i in range(101):
            self.add_file(REMOTE, f"empty-{i:03}.txt", b"")
        folder = "子目录 with spaces"
        nested = f"{REMOTE}/{folder}"
        self.server.dirs[REMOTE].append({"type": "dir", "name": folder})
        self.server.dirs[nested] = [{"type": "dir", "name": "empty directory"}]
        self.server.dirs[f"{nested}/empty directory"] = []
        name = "image % # + ? 中文.txt"
        payload = b"partial then remaining file contents"
        self.add_file(nested, name, payload)
        self.add_file(nested, ".hidden", b"hidden")
        self.add_file(nested, "trailing newline\n", b"newline")
        self.add_file(nested, "already.txt", b"complete")
        local_folder = self.dest / folder
        local_folder.mkdir(parents=True)
        (local_folder / name).write_bytes(payload[:7])
        (local_folder / "already.txt").write_bytes(b"complete")
        (self.dest / "unrelated.txt").write_text("preserve me")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((local_folder / name).read_bytes(), payload)
        self.assertEqual((local_folder / "trailing newline\n").read_bytes(), b"newline")
        self.assertEqual((local_folder / ".hidden").read_bytes(), b"hidden")
        self.assertTrue((local_folder / "empty directory").is_dir())
        self.assertEqual((self.dest / "unrelated.txt").read_text(), "preserve me")
        self.assertIn((REMOTE, 2), self.server.pages)
        self.assertIn((f"{nested}/{name}", "bytes=7-"), self.server.transfers)
        self.assertNotIn(f"{nested}/already.txt", [path for path, _ in self.server.transfers])
        self.assertNotIn("test-token-not-a-real-credential", result.stdout + result.stderr)
        transfers = len(self.server.transfers)
        again = self.run_script()
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(len(self.server.transfers), transfers)

    def test_empty_directory(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.dest.is_dir())

    def test_larger_local_file_is_preserved(self):
        self.add_file(REMOTE, "file.bin", b"small")
        self.dest.mkdir()
        target = self.dest / "file.bin"
        target.write_bytes(b"larger local data")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_bytes(), b"larger local data")
        self.assertEqual(self.server.transfers, [])

    def test_symlink_and_parent_traversal_are_rejected(self):
        outside = Path(self.temp.name) / "outside.txt"
        outside.write_text("preserve outside")
        self.add_file(REMOTE, "file.bin", b"new content")
        self.dest.mkdir()
        (self.dest / "file.bin").symlink_to(outside)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(outside.read_text(), "preserve outside")
        self.server.dirs[REMOTE] = [{"type": "file", "name": "../outside.txt", "size": 1}]
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(outside.read_text(), "preserve outside")

    def test_download_size_mismatch_fails(self):
        self.add_file(REMOTE, "short.bin", b"short")
        self.server.dirs[REMOTE][0]["size"] = "100"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Directory download complete", result.stdout)

    def test_missing_remote_directory_fails(self):
        result = self.run_script("DataSet/missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Directory download complete", result.stdout)


if __name__ == "__main__":
    unittest.main()
