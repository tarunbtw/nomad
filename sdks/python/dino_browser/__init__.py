"""
Dino Browser Python SDK (v0.42.0)
High-speed native macOS agentic browser driver, token-optimized perception, and Unix domain socket bridge.
"""

import http.client
import json
import os
import socket
import subprocess
import sys
import urllib.parse
from typing import Optional, Dict, Any, List, Union

__version__ = "0.42.0"


class UnixHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection over a local Unix domain socket."""

    def __init__(self, socket_path: str, timeout: float = 30.0):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.socket_path)


class PlaybookNamespace:
    def __init__(self, client: "Dino"):
        self._client = client

    def record(self, name: str) -> Dict[str, Any]:
        return self._client._request("POST", "/playbook/record", {"name": name})

    def stop(self) -> Dict[str, Any]:
        return self._client._request("POST", "/playbook/stop")

    def run(self, name: str, variables: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
        return self._client._request("POST", "/playbook/replay", {"name": name, "variables": variables or {}})

    def list(self) -> Dict[str, Any]:
        return self._client._request("GET", "/playbook/list")

    def export(self, name: str) -> Dict[str, Any]:
        qs = urllib.parse.urlencode({"name": name})
        return self._client._request("GET", f"/playbook/export?{qs}")

    def delete(self, name: str) -> Dict[str, Any]:
        qs = urllib.parse.urlencode({"name": name})
        return self._client._request("DELETE", f"/playbook?{qs}")


class RouteNamespace:
    def __init__(self, client: "Dino"):
        self._client = client

    def block(self, pattern: str) -> Dict[str, Any]:
        return self._client._request("POST", "/route", {"pattern": pattern, "action": "abort"})

    def mock(self, pattern: str, body: Any, status: int = 200, headers: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
        return self._client._request("POST", "/route", {
            "pattern": pattern,
            "action": "mock",
            "body": body,
            "status": status,
            "headers": headers
        })

    def list(self) -> Dict[str, Any]:
        return self._client._request("GET", "/route/list")

    def clear(self) -> Dict[str, Any]:
        return self._client._request("DELETE", "/route")


class HITLNamespace:
    def __init__(self, client: "Dino"):
        self._client = client

    def status(self) -> Dict[str, Any]:
        return self._client._request("GET", "/hitl/status")

    def resolve(self) -> Dict[str, Any]:
        return self._client._request("POST", "/hitl/resolve")


class Dino:
    """
    Client for interacting with Dino's native Apple Silicon browser engine and Unix socket daemon.
    """

    def __init__(
        self,
        port: int = 9222,
        host: str = "127.0.0.1",
        socket_path: Optional[str] = None,
        token: Optional[str] = None
    ):
        if sys.platform != "darwin":
            sys.stderr.write("Dino is a native Apple Silicon browser engine and runs on macOS.\n")

        self.port = port
        self.host = host
        self.socket_path = socket_path or self._resolve_socket_path()
        self.token = token or self._load_token()

        self.playbook = PlaybookNamespace(self)
        self.route = RouteNamespace(self)
        self.hitl = HITLNamespace(self)

    @staticmethod
    def _load_token() -> str:
        env = os.environ.get("DINO_TOKEN")
        if env:
            return env.strip()
        token_path = os.path.expanduser("~/.dino/agent-token")
        if os.path.exists(token_path):
            try:
                with open(token_path, "r", encoding="utf-8") as f:
                    return f.read().strip()
            except Exception:
                pass
        return ""

    @staticmethod
    def _resolve_socket_path() -> Optional[str]:
        sock = os.path.expanduser("~/.dino/dino.sock")
        if os.path.exists(sock):
            return sock

        workers_dir = os.path.expanduser("~/.dino/workers")
        if os.path.exists(workers_dir):
            try:
                for entry in os.listdir(workers_dir):
                    if entry.endswith(".sock"):
                        return os.path.join(workers_dir, entry)
            except Exception:
                pass
        return None

    @staticmethod
    def _resolve_binary() -> Optional[str]:
        env_bin = os.environ.get("DINO_BIN")
        if env_bin and os.path.exists(env_bin):
            return env_bin
        app_bin = "/Applications/Dino.app/Contents/MacOS/dino"
        if os.path.exists(app_bin):
            return app_bin
        user_bin = os.path.expanduser("~/.dino/bin/dino")
        if os.path.exists(user_bin):
            return user_bin
        import shutil
        return shutil.which("dino")

    @classmethod
    def start_worker(cls, profile: str = "agent", idle_timeout: int = 60, port: Optional[int] = None) -> "Dino":
        """Spins up a headless Dino worker process and returns a connected client."""
        binary = cls._resolve_binary() or "dino"
        cmd = [binary, "start", "--profile", profile, "--idle-timeout", str(idle_timeout)]
        if port:
            cmd.extend(["--port", str(port)])
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        for line in res.stdout.splitlines():
            if "HTTP: http://127.0.0.1:" in line:
                p = int(line.split(":")[-1].strip())
                return cls(port=p)
        return cls(port=port or 9222)

    launch = start_worker

    def _get_connection(self, timeout: float = 30.0) -> http.client.HTTPConnection:
        if self.socket_path and os.path.exists(self.socket_path):
            return UnixHTTPConnection(self.socket_path, timeout=timeout)
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout)

    def _request(self, method: str, endpoint: str, body: Optional[Any] = None, timeout: float = 30.0) -> Any:
        headers = {
            "Content-Type": "application/json"
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"

        payload = json.dumps(body).encode("utf-8") if body is not None else None
        if payload is not None:
            headers["Content-Length"] = str(len(payload))

        conn = self._get_connection(timeout=timeout)
        try:
            conn.request(method, endpoint, body=payload, headers=headers)
            resp = conn.getresponse()
            raw = resp.read().decode("utf-8")
            if resp.status >= 400:
                raise RuntimeError(f"Dino HTTP {resp.status}: {raw}")
            if not raw:
                return None
            try:
                return json.loads(raw)
            except Exception:
                return raw
        finally:
            conn.close()

    # --- Status & Tabs ---

    def status(self) -> Dict[str, Any]:
        """Returns browser and worker status."""
        return self._request("GET", "/status")

    def cdp_version(self) -> Dict[str, Any]:
        """Returns Chrome DevTools Protocol version declaration."""
        return self._request("GET", "/json/version")

    def tabs(self) -> List[Dict[str, Any]]:
        """Lists active tabs."""
        res = self._request("GET", "/tabs")
        return res.get("tabs", []) if isinstance(res, dict) else []

    def new_tab(self, url: str = "", is_ghost: bool = False, select: bool = True) -> Dict[str, Any]:
        """Creates a new browser tab."""
        return self._request("POST", "/tabs/new", {"url": url, "isGhost": is_ghost, "select": select})

    def switch_tab(self, tab_id_or_index: Union[str, int]) -> Dict[str, Any]:
        """Switches the active tab by ID or index."""
        if isinstance(tab_id_or_index, int):
            body = {"index": tab_id_or_index}
        else:
            body = {"tabId": tab_id_or_index}
        return self._request("POST", "/tabs/switch", body)

    def close_tab(self, tab_id_or_index: Optional[Union[str, int]] = None) -> Dict[str, Any]:
        """Closes a tab by ID or index, or closes the active tab."""
        if isinstance(tab_id_or_index, int):
            body = {"index": tab_id_or_index}
        elif tab_id_or_index:
            body = {"tabId": tab_id_or_index}
        else:
            body = {}
        return self._request("POST", "/tabs/close", body)

    # --- Navigation ---

    def goto(self, url: str, allow_local_files: bool = False) -> Dict[str, Any]:
        """Navigates active tab to a URL."""
        return self._request("POST", "/navigate", {
            "action": "url",
            "url": url,
            "allowLocalFiles": allow_local_files
        })

    def navigate(self, url: str, allow_local_files: bool = False) -> Dict[str, Any]:
        """Alias for goto()."""
        return self.goto(url, allow_local_files=allow_local_files)

    def back(self) -> Dict[str, Any]:
        """Navigates back."""
        return self._request("POST", "/navigate", {"action": "back"})

    def forward(self) -> Dict[str, Any]:
        """Navigates forward."""
        return self._request("POST", "/navigate", {"action": "forward"})

    def reload(self) -> Dict[str, Any]:
        """Reloads active tab."""
        return self._request("POST", "/navigate", {"action": "reload"})

    # --- Perception & Inspection ---

    def snapshot(
        self,
        mode: str = "text",
        limit: Optional[int] = None,
        offset: Optional[int] = None,
        viewport_only: bool = False,
        target: Optional[str] = None,
        role: Optional[str] = None,
        text: Optional[str] = None,
        depth: Optional[int] = None
    ) -> Dict[str, Any]:
        """Captures a token-optimized semantic tree snapshot."""
        params: Dict[str, str] = {"mode": mode}
        if limit is not None:
            params["limit"] = str(limit)
        if offset is not None:
            params["offset"] = str(offset)
        if viewport_only:
            params["viewportOnly"] = "true"
        if target:
            params["target"] = target
        if role:
            params["role"] = role
        if text:
            params["text"] = text
        if depth is not None:
            params["depth"] = str(depth)

        qs = urllib.parse.urlencode(params)
        return self._request("GET", f"/snapshot?{qs}")

    def diff(self, tab_id: Optional[str] = None) -> Dict[str, Any]:
        """Returns minimal differential DOM changes since last snapshot/diff."""
        endpoint = f"/diff?tabId={urllib.parse.quote(tab_id)}" if tab_id else "/diff"
        return self._request("GET", endpoint)

    def find(
        self,
        role: Optional[str] = None,
        text: Optional[str] = None,
        selector: Optional[str] = None,
        viewport_only: bool = False
    ) -> Dict[str, Any]:
        """Searches for elements matching criteria without full tree cost."""
        params: Dict[str, str] = {}
        if role:
            params["role"] = role
        if text:
            params["text"] = text
        if selector:
            params["selector"] = selector
        if viewport_only:
            params["viewportOnly"] = "true"

        qs = urllib.parse.urlencode(params)
        return self._request("GET", f"/find?{qs}")

    # --- Atomic Actions ---

    def click(self, target: str, native: bool = False, tab_id: Optional[str] = None) -> Dict[str, Any]:
        """Clicks an element by ref (e.g. 'e1') or selector."""
        return self._request("POST", "/action", {
            "action": "click",
            "target": target,
            "native": native,
            "tabId": tab_id
        })

    def dblclick(self, target: str, native: bool = False, tab_id: Optional[str] = None) -> Dict[str, Any]:
        """Double clicks an element."""
        return self._request("POST", "/action", {
            "action": "dblclick",
            "target": target,
            "native": native,
            "tabId": tab_id
        })

    def type(
        self,
        target: str,
        text: str,
        submit: bool = False,
        clear: bool = False,
        native: bool = False,
        tab_id: Optional[str] = None
    ) -> Dict[str, Any]:
        """Types text into an element."""
        return self._request("POST", "/action", {
            "action": "type",
            "target": target,
            "text": text,
            "submit": submit,
            "clear": clear,
            "native": native,
            "tabId": tab_id
        })

    def press(self, key: str, modifiers: Optional[List[str]] = None, tab_id: Optional[str] = None) -> Dict[str, Any]:
        """Presses a key (e.g. 'Enter', 'Escape', 'Tab')."""
        return self._request("POST", "/action", {
            "action": "press",
            "key": key,
            "modifiers": modifiers or [],
            "tabId": tab_id
        })

    def scroll(
        self,
        direction: str = "down",
        amount: int = 300,
        native: bool = False,
        tab_id: Optional[str] = None
    ) -> Dict[str, Any]:
        """Scrolls the page or element."""
        return self._request("POST", "/action", {
            "action": "scroll",
            "direction": direction,
            "amount": amount,
            "native": native,
            "tabId": tab_id
        })

    def drag(self, from_target: str, to_target: str, native: bool = True, tab_id: Optional[str] = None) -> Dict[str, Any]:
        """Drags from one element to another."""
        return self._request("POST", "/action", {
            "action": "drag",
            "target": from_target,
            "toTarget": to_target,
            "native": native,
            "tabId": tab_id
        })

    def hover(self, target: str, tab_id: Optional[str] = None) -> Dict[str, Any]:
        """Hovers over an element."""
        return self._request("POST", "/action", {
            "action": "hover",
            "target": target,
            "tabId": tab_id
        })

    def wait(
        self,
        mode: str = "auto",
        selector: Optional[str] = None,
        timeout: Optional[int] = None,
        duration: Optional[float] = None,
        text: Optional[str] = None,
        tab_id: Optional[str] = None
    ) -> Dict[str, Any]:
        """Waits for page conditions: auto stability, selector, networkidle, or duration."""
        body: Dict[str, Any] = {"mode": mode}
        if selector:
            body["selector"] = selector
        if timeout is not None:
            body["timeout"] = timeout
        if duration is not None:
            body["duration"] = duration
        if text:
            body["text"] = text
        if tab_id:
            body["tabId"] = tab_id
        return self._request("POST", "/wait", body)

    def evaluate(self, expression: str, world: str = "isolated", tab_id: Optional[str] = None) -> Any:
        """Evaluates JavaScript expression in isolated or page world."""
        res = self._request("POST", "/evaluate", {
            "expression": expression,
            "world": world,
            "tabId": tab_id
        })
        return res.get("result") if isinstance(res, dict) else res

    # --- Vision & Screenshot ---

    def screenshot(
        self,
        file: Optional[str] = None,
        labeled: bool = False,
        crop: bool = False,
        clip: Optional[Dict[str, int]] = None,
        element_id: Optional[str] = None,
        tab_id: Optional[str] = None
    ) -> bytes:
        """
        Captures a high-resolution screenshot.
        Set crop=True with labeled=True to crop image to the active interaction region (Set-of-Marks).
        """
        params: Dict[str, str] = {}
        if labeled:
            params["labeled"] = "true"
        if crop:
            params["somCrop"] = "true"
        if element_id:
            params["elementId"] = element_id
        if clip:
            params["clip"] = f"{clip['x']},{clip['y']},{clip['width']},{clip['height']}"
        if tab_id:
            params["tabId"] = tab_id

        qs = urllib.parse.urlencode(params)
        endpoint = f"/screenshot?{qs}" if qs else "/screenshot"

        headers = {}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"

        conn = self._get_connection(timeout=30.0)
        try:
            conn.request("GET", endpoint, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            if resp.status >= 400:
                raise RuntimeError(f"Dino HTTP {resp.status}: {data.decode('utf-8', errors='ignore')}")
            if file:
                with open(file, "wb") as f:
                    f.write(data)
            return data
        finally:
            conn.close()


dino = Dino()
__all__ = ["Dino", "dino", "__version__"]
