#!/usr/bin/env python3
"""
Privacy-safe local MCP smoke test.

This validates the app-owned local MCP path only. It intentionally does not
start tunnel-client, create drafts, change message flags, or print personal
data.
"""

from __future__ import annotations

import json
import os
import select
import subprocess
import sys
import time
from datetime import date, timedelta
from pathlib import Path
from typing import Any


DEFAULT_SOCKET = Path.home() / "Library/Application Support/macmcp/mcp.sock"
DEFAULT_BRIDGE_CANDIDATES = (
    Path("/Applications/MacMCP.app/Contents/MacOS/macmcp-bridge"),
    Path.home() / "Applications/MacMCP.app/Contents/MacOS/macmcp-bridge",
    Path.home() / ".local/opt/macmcp/bin/macmcp-bridge",
)
MCP_REQUEST_TIMEOUT_SECONDS = float(os.environ.get("MACMCP_VALIDATION_MCP_TIMEOUT", "120"))


class ValidationError(Exception):
    pass


class MCPClient:
    def __init__(self, command: str, args: list[str]) -> None:
        self.process = subprocess.Popen(
            [command, *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.next_id = 1

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        payload: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        self._write(payload)

    def request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        request_id = self.next_id
        self.next_id += 1
        payload: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        self._write(payload)
        deadline = time.monotonic() + MCP_REQUEST_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            message = self._read_message(deadline)
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise ValidationError("mcp request failed")
            return message.get("result")
        raise ValidationError("mcp request timed out")

    def _write(self, payload: dict[str, Any]) -> None:
        if self.process.stdin is None:
            raise ValidationError("mcp stdin unavailable")
        self.process.stdin.write(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
        self.process.stdin.flush()

    def _read_message(self, deadline: float) -> dict[str, Any]:
        if self.process.stdout is None:
            raise ValidationError("mcp stdout unavailable")
        while time.monotonic() < deadline:
            line = self._readline(deadline)
            if not line:
                if self.process.poll() is not None:
                    raise ValidationError("mcp process exited")
                continue
            try:
                return json.loads(line.strip().decode("utf-8"))
            except json.JSONDecodeError as error:
                raise ValidationError("mcp returned invalid json") from error
        raise ValidationError("mcp response timed out")

    def _readline(self, deadline: float) -> bytes:
        if self.process.stdout is None:
            raise ValidationError("mcp stdout unavailable")
        line = bytearray()
        while time.monotonic() < deadline:
            remaining = max(0.0, deadline - time.monotonic())
            readable, _, _ = select.select(
                [self.process.stdout.fileno()], [], [], min(remaining, 1.0)
            )
            if not readable:
                continue
            chunk = os.read(self.process.stdout.fileno(), 1)
            if not chunk:
                return bytes(line)
            line.extend(chunk)
            if chunk == b"\n":
                return bytes(line)
        return b""


EXPECTED_TOOLS = {
    "bridge_status",
    "mail.list_accounts",
    "mail.server_info",
    "mail.list_folders",
    "mail.search",
    "mail.read",
    "mail.read_attachment_text",
    "calendar.list",
    "calendar.events",
    "calendar.upcoming",
    "calendar.search",
    "reminders.list",
    "reminders.search",
    "reminders.tags",
    "mail.create_managed_draft",
    "mail.update_managed_draft",
    "mail.mark",
}


def main() -> int:
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass

    client: MCPClient | None = None
    try:
        command, args = load_mcp_command()
        report = load_diagnostics(command)
        validate_diagnostics(report)
        print("local_mcp_validation")
        print("tunnel=SKIP local_only=true")
        print(f"configured_accounts={report['configuration']['mailAccountCount']}")
        print(f"approved_clients={report['clientApprovals']['approvedCount']}")

        client = MCPClient(command, args)
        initialize(client)
        tools = client.request("tools/list").get("tools", [])
        validate_tool_surface(tools)
        print(f"tool_surface=PASS tools={len(tools)} structured_output=true")

        status = call_tool(client, "bridge_status", {})
        validate_bridge_status(status)
        print("bridge_status=PASS")

        accounts = decode_result(call_tool(client, "mail.list_accounts", {}))
        account_ids = account_ids_from_result(accounts)
        if not account_ids:
            raise ValidationError("mail account list is empty")
        for account_id in account_ids:
            call_tool(client, "mail.list_folders", {"account_id": account_id})
            search = decode_result(
                call_tool(
                    client,
                    "mail.search",
                    {"account_id": account_id, "folder": "INBOX", "limit": 1},
                )
            )
            message_id = first_message_id(search)
            if message_id:
                call_tool(
                    client,
                    "mail.read",
                    {"message_id": message_id, "max_body_chars": 1},
                )
        print(f"mail_reader=PASS accounts={len(account_ids)}")

        call_tool(client, "calendar.list", {})
        today = date.today()
        call_tool(
            client,
            "calendar.events",
            {
                "start_date": today.isoformat(),
                "end_date": (today + timedelta(days=1)).isoformat(),
                "limit": 1,
            },
        )
        print("calendar_reader=PASS")

        call_tool(client, "reminders.list", {"limit": 1})
        print("reminders_reader=PASS")
        client.close()
        client = None

        print("result=PASS")
        return 0
    except Exception as error:
        print("result=FAIL")
        print(f"reason={safe_reason(error)}")
        return 1
    finally:
        if client is not None:
            client.close()


def load_mcp_command() -> tuple[str, list[str]]:
    local_config = Path(
        os.environ.get(
            "MACMCP_LOCAL_CONFIG",
            str(Path.home() / ".local/opt/macmcp/share/mcp.local.json"),
        )
    ).expanduser()
    if local_config.is_file():
        try:
            servers = json.loads(local_config.read_text(encoding="utf-8"))["mcpServers"]
            server = servers.get("macmcp") or servers["mac-agent-bridge"]
            command = str(server["command"])
            args = [str(arg) for arg in server.get("args", [])]
        except Exception as error:
            raise ValidationError("installed mcp config is invalid") from error
    else:
        command = os.environ.get("MACMCP_BRIDGE_PATH", "")
        if not command:
            command = next(
                (str(candidate) for candidate in DEFAULT_BRIDGE_CANDIDATES if candidate.is_file()),
                "",
            )
        socket_path = Path(
            os.environ.get("MACMCP_IPC_SOCKET", str(DEFAULT_SOCKET))
        ).expanduser()
        args = ["--stdio-proxy", str(socket_path)]

    if not command or not Path(command).is_file() or not os.access(command, os.X_OK):
        raise ValidationError("installed bridge binary is missing")
    return command, args


def load_diagnostics(command: str) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            [command, "--diagnose-json"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
        return json.loads(completed.stdout)
    except Exception as error:
        raise ValidationError("local diagnostics are unavailable") from error


def validate_diagnostics(report: dict[str, Any]) -> None:
    if report.get("schemaVersion") != 1:
        raise ValidationError("unsupported diagnostics schema")
    configuration = report.get("configuration") or {}
    if configuration.get("availability") != "available":
        raise ValidationError("local configuration is unavailable")
    if int(configuration.get("mailAccountCount", 0)) < 1:
        raise ValidationError("no mail accounts configured")
    bridge = report.get("bridge") or {}
    status = bridge.get("status") or {}
    if bridge.get("availability") != "available":
        raise ValidationError("bridge is unavailable")
    if status.get("mode") != "reader":
        raise ValidationError("bridge mode is invalid")
    for component in ("mail", "calendar", "reminders"):
        if status.get(component) != "ready":
            raise ValidationError(f"{component} component is not ready")
    if not isinstance(status.get("writeCapabilitiesEnabled"), bool):
        raise ValidationError("write capability status is invalid")
    approvals = report.get("clientApprovals") or {}
    if approvals.get("availability") != "available" or approvals.get("approvalPending"):
        raise ValidationError("local MCP client approval is not ready")
    if int(approvals.get("approvedCount", 0)) < 1:
        raise ValidationError("no approved local MCP client")


def initialize(client: MCPClient) -> None:
    client.request(
        "initialize",
        {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "macmcp-local-validation", "version": "0.1"},
        },
    )
    client.notify("notifications/initialized")


def validate_tool_surface(tools: list[dict[str, Any]]) -> None:
    names = {str(tool.get("name", "")) for tool in tools}
    if not EXPECTED_TOOLS.issubset(names):
        raise ValidationError("mcp tool surface is incomplete")
    if any(is_forbidden_tool(name) for name in names):
        raise ValidationError("mcp exposed a forbidden tool")
    if any(not isinstance(tool.get("outputSchema"), dict) for tool in tools):
        raise ValidationError("mcp tool is missing output schema")


def is_forbidden_tool(name: str) -> bool:
    lowered = name.lower()
    mutation_words = ("send", "reply", "forward", "delete", "move", "archive", "complete")
    return any(word in lowered for word in mutation_words) or (
        "attachment" in lowered and lowered != "mail.read_attachment_text"
    )


def call_tool(client: MCPClient, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    result = client.request("tools/call", {"name": name, "arguments": arguments})
    if not isinstance(result, dict) or result.get("isError"):
        raise ValidationError(f"mcp tool call failed: {name}")
    if not isinstance(result.get("structuredContent"), dict):
        raise ValidationError(f"mcp tool result has no structured output: {name}")
    return result


def validate_bridge_status(result: dict[str, Any]) -> None:
    status = decode_result(result)
    if not isinstance(status, dict):
        raise ValidationError("bridge status result is invalid")
    for component in ("mail", "calendar", "reminders"):
        if status.get(component) != "ready":
            raise ValidationError(f"bridge status reports {component} not ready")


def decode_result(result: dict[str, Any]) -> Any:
    content = result.get("content") or []
    if not content or not isinstance(content[0], dict):
        raise ValidationError("mcp result has no content")
    text = content[0].get("text", "")
    if not isinstance(text, str):
        raise ValidationError("mcp result content is invalid")
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start < 0 or end < start:
            raise ValidationError("mcp result is not json")
        try:
            value = json.loads(text[start : end + 1])
        except json.JSONDecodeError as error:
            raise ValidationError("mcp result is not json") from error

    # Personal-data tools use the same bounded envelope in text and
    # structuredContent. The smoke test needs the inner object only to find
    # opaque account IDs; it never prints the decoded payload.
    if isinstance(value, dict) and isinstance(value.get("untrusted_data"), str):
        inner = value["untrusted_data"]
        try:
            return json.loads(inner)
        except json.JSONDecodeError:
            start = inner.find("{")
            end = inner.rfind("}")
            if start >= 0 and end >= start:
                try:
                    return json.loads(inner[start : end + 1])
                except json.JSONDecodeError:
                    pass
    return value


def account_ids_from_result(result: Any) -> list[str]:
    if not isinstance(result, dict) or not isinstance(result.get("accounts"), list):
        raise ValidationError("mail account result is invalid")
    account_ids = [item.get("id") for item in result["accounts"] if isinstance(item, dict)]
    if any(not isinstance(account_id, str) or not account_id for account_id in account_ids):
        raise ValidationError("mail account id is invalid")
    return account_ids


def first_message_id(result: Any) -> str | None:
    if not isinstance(result, dict) or not isinstance(result.get("messages"), list):
        raise ValidationError("mail search result is invalid")
    for message in result["messages"]:
        if isinstance(message, dict) and isinstance(message.get("message_id"), str):
            return message["message_id"]
    return None


def safe_reason(error: Exception) -> str:
    return (str(error) or error.__class__.__name__)[:160]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("result=INTERRUPTED")
        sys.exit(130)
