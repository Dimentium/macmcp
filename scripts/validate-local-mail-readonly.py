#!/usr/bin/env python3
"""
Privacy-safe local IMAP/MCP validation.

This script intentionally prints only aggregate PASS/FAIL status. It suppresses
raw MCP, IMAP, Keychain, message, folder, UID, subject, sender, and body data.
"""

from __future__ import annotations

import base64
import hashlib
import imaplib
import json
import os
import re
import select
import socket
import ssl
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SERVICE = "com.openai.mac-agent-bridge.icloud-imap"
DEFAULT_CONFIG = Path.home() / ".local/opt/mac-agent-bridge/share/mcp.local.json"
DEFAULT_APP_CONFIG = Path.home() / "Library/Application Support/mac-agent-bridge/launch.json"
MAX_MESSAGES_FOR_FLAGS = 50
MCP_REQUEST_TIMEOUT_SECONDS = float(os.environ.get("MACMCP_VALIDATION_MCP_TIMEOUT", "120"))


@dataclass(frozen=True)
class Account:
    label: str
    username: str
    host: str
    port: int
    security: str


@dataclass(frozen=True)
class Snapshot:
    uidvalidity: str
    uidnext: str
    exists: int
    unseen: int
    membership_hash: str
    sampled_flags_hash: str
    target_flags_hash: str


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
        raise ValidationError(f"mcp request timed out: {self.stderr_summary()}")

    def _write(self, payload: dict[str, Any]) -> None:
        if self.process.stdin is None:
            raise ValidationError("mcp stdin unavailable")
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n"
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def _read_message(self, deadline: float) -> dict[str, Any]:
        if self.process.stdout is None:
            raise ValidationError("mcp stdout unavailable")
        while time.monotonic() < deadline:
            line = self._readline(deadline)
            if not line:
                if self.process.poll() is not None:
                    raise ValidationError(f"mcp process exited: {self.stderr_summary()}")
                raise ValidationError(f"mcp stdout timed out: {self.stderr_summary()}")
            stripped = line.strip()
            if stripped:
                return json.loads(stripped.decode("utf-8"))
        raise ValidationError(f"mcp stdout timed out: {self.stderr_summary()}")

    def _readline(self, deadline: float) -> bytes:
        if self.process.stdout is None:
            raise ValidationError("mcp stdout unavailable")
        line = bytearray()
        while time.monotonic() < deadline:
            if not self._stdout_ready(deadline):
                if self.process.poll() is not None:
                    return bytes(line)
                continue
            chunk = os.read(self.process.stdout.fileno(), 1)
            if not chunk:
                return bytes(line)
            line.extend(chunk)
            if chunk == b"\n":
                return bytes(line)
        return b""

    def _stdout_ready(self, deadline: float) -> bool:
        if self.process.stdout is None:
            raise ValidationError("mcp stdout unavailable")
        remaining = max(0.0, deadline - time.monotonic())
        if remaining == 0:
            return False
        readable, _, _ = select.select([self.process.stdout.fileno()], [], [], min(remaining, 1.0))
        return bool(readable)

    def stderr_summary(self) -> str:
        if self.process.stderr is None:
            return "no stderr"
        try:
            chunks: list[bytes] = []
            deadline = time.monotonic() + 0.25
            while len(b"".join(chunks)) < 4096 and time.monotonic() < deadline:
                readable, _, _ = select.select([self.process.stderr.fileno()], [], [], 0)
                if not readable:
                    break
                chunk = os.read(self.process.stderr.fileno(), 4096 - len(b"".join(chunks)))
                if not chunk:
                    break
                chunks.append(chunk)
            data = b"".join(chunks)
        except Exception:
            return "stderr unavailable"
        text = data.decode("utf-8", errors="replace").strip()
        if not text:
            return "empty stderr"
        return safe_reason(text)


def main() -> int:
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    try:
        config_path = Path(os.environ.get("MACMCP_LOCAL_CONFIG", str(DEFAULT_CONFIG))).expanduser()
        command, args = load_mcp_config(config_path)
        app_config_path = Path(os.environ.get("MACMCP_APP_CONFIG", str(DEFAULT_APP_CONFIG))).expanduser()
        app_args = load_app_args(app_config_path)
        accounts = parse_accounts(args) or parse_accounts(app_args)
        if not accounts:
            raise ValidationError("no mail accounts configured")
        mail_command = command
        mail_args = args if "--stdio-proxy" in args else mail_only_args(args)

        print("local-mail-readonly-validation")
        print(f"accounts_configured={len(accounts)}")

        client = MCPClient(mail_command, mail_args)
        try:
            initialize(client)
            validate_tool_surface(client)
            validate_accounts(client, accounts)
        finally:
            client.close()

        print("result=PASS")
        return 0
    except Exception as error:
        print("result=FAIL")
        print(f"reason={safe_reason(error)}")
        return 1


def load_mcp_config(path: Path) -> tuple[str, list[str]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        server = data["mcpServers"]["mac-agent-bridge"]
        command = str(server["command"])
        args = [str(arg) for arg in server.get("args", [])]
    except Exception as exc:
        raise ValidationError("installed mcp config is unavailable or invalid") from exc
    if not Path(command).exists():
        raise ValidationError("installed bridge binary is missing")
    return command, args


def load_app_args(path: Path) -> list[str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return [str(arg) for arg in data.get("args", [])]
    except Exception:
        return []


def parse_accounts(args: list[str]) -> list[Account]:
    accounts: list[Account] = []
    index = 0
    while index < len(args):
        option = args[index]
        value = args[index + 1] if index + 1 < len(args) else ""
        if option == "--allow-unsafe-plain-imap":
            index += 1
        elif option == "--icloud-address":
            accounts.append(
                Account(next_label("icloud", accounts), value, "imap.mail.me.com", 993, "tls")
            )
            index += 2
        elif option == "--gmail-address":
            accounts.append(
                Account(next_label("gmail", accounts), value, "imap.gmail.com", 993, "tls")
            )
            index += 2
        elif option == "--mail-account":
            accounts.append(parse_custom_account(value))
            index += 2
        else:
            index += 2 if option.startswith("--") else 1
    return accounts


def parse_custom_account(value: str) -> Account:
    if "=" not in value:
        raise ValidationError("custom account config is invalid")
    label, rest = value.split("=", 1)
    parts = rest.split(",")
    if len(parts) == 1:
        raise ValidationError("custom account host is required for validation")
    username = parts[0]
    host = parts[1]
    port = int(parts[2]) if len(parts) >= 3 and parts[2] else 993
    security = parts[3] if len(parts) >= 4 and parts[3] else "tls"
    return Account(label, username, host, port, security)


def next_label(base: str, accounts: list[Account]) -> str:
    existing = {account.label for account in accounts}
    if base not in existing:
        return base
    suffix = 2
    while f"{base}{suffix}" in existing:
        suffix += 1
    return f"{base}{suffix}"


def mail_only_args(args: list[str]) -> list[str]:
    result: list[str] = []
    index = 0
    while index < len(args):
        option = args[index]
        if option == "--allow-unsafe-plain-imap":
            result.append(option)
            index += 1
            continue
        if option == "--eventkit-sidecar":
            index += 2
            continue
        result.append(option)
        if option.startswith("--") and index + 1 < len(args):
            result.append(args[index + 1])
            index += 2
        else:
            index += 1
    return result


def initialize(client: MCPClient) -> None:
    client.request(
        "initialize",
        {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "local-mail-readonly-validation", "version": "0.1"},
        },
    )
    client.notify("notifications/initialized")


def validate_tool_surface(client: MCPClient) -> None:
    result = client.request("tools/list")
    names = sorted(tool.get("name", "") for tool in result.get("tools", []))
    expected_mail = {
        "bridge_status",
        "mail.list_accounts",
        "mail.server_info",
        "mail.list_folders",
        "mail.search",
        "mail.read",
        "mail.read_attachment_text",
        "mail.create_managed_draft",
        "mail.update_managed_draft",
        "mail.mark",
    }
    if not expected_mail.issubset(set(names)):
        raise ValidationError("mcp mail tool surface is incomplete")
    forbidden = [name for name in names if is_forbidden_tool(name)]
    if forbidden:
        raise ValidationError("mcp exposed a forbidden mail tool")
    print("tool_surface=PASS")


def is_forbidden_tool(name: str) -> bool:
    lowered = name.lower()
    mutation_words = [
        "send",
        "reply",
        "forward",
        "delete",
        "move",
        "archive",
        "complete",
    ]
    return any(word in lowered for word in mutation_words) or (
        "attachment" in lowered and lowered != "mail.read_attachment_text"
    )


def validate_accounts(client: MCPClient, accounts: list[Account]) -> None:
    call_tool(client, "bridge_status", {})
    call_tool(client, "mail.list_accounts", {})
    print("mcp_account_auth=PASS")

    ordered_accounts = sorted(accounts, key=lambda account: (0 if account.label.startswith("gmail") else 1, account.label))
    for ordinal, account in enumerate(ordered_accounts, start=1):
        password = read_keychain_password(account.username)
        target_uid = newest_uid(account, password)
        if target_uid is None:
            print(f"account_{ordinal}_imap_snapshot=PASS_EMPTY")
            continue
        before = snapshot(account, password, target_uid=target_uid)

        print(f"account_{ordinal}_imap_snapshot=PASS")
        search_result = call_tool(
            client,
            "mail.search",
            {"account_id": account.label, "folder": "INBOX", "limit": 1},
            context=f"account_{ordinal}_search",
        )
        message_id = first_message_id(search_result)
        print(f"account_{ordinal}_search=PASS")
        call_tool(
            client,
            "mail.read",
            {"message_id": message_id, "max_body_chars": 1},
            context=f"account_{ordinal}_read",
        )
        print(f"account_{ordinal}_read=PASS")
        after = snapshot(account, password, target_uid=target_uid)
        compare_snapshots(before, after)
        print(f"account_{ordinal}_readonly=PASS")


def call_tool(
    client: MCPClient,
    name: str,
    arguments: dict[str, Any],
    context: str | None = None,
) -> Any:
    result = client.request("tools/call", {"name": name, "arguments": arguments})
    if result.get("isError"):
        detail = context or name
        raise ValidationError(f"mcp tool call failed at {detail}")
    return result


def first_message_id(call_result: dict[str, Any]) -> str:
    try:
        content = call_result.get("content", [])
        text = content[0].get("text", "")
        payload = json.loads(extract_json_object(text))
        messages = payload.get("messages", [])
        if not messages:
            raise ValidationError("mcp search returned no messages")
        message_id = messages[0].get("message_id", "")
        if not message_id:
            raise ValidationError("mcp search result did not include a message handle")
        return str(message_id)
    except ValidationError:
        raise
    except Exception as exc:
        raise ValidationError("mcp search result shape is unsupported") from exc


def extract_json_object(text: str) -> str:
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end < start:
        raise ValidationError("mcp response did not contain json")
    return text[start : end + 1]


def read_keychain_password(account: str) -> str:
    try:
        completed = subprocess.run(
            ["security", "find-generic-password", "-s", SERVICE, "-a", account, "-w"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=20,
        )
    except subprocess.TimeoutExpired as exc:
        raise ValidationError("keychain lookup timed out") from exc
    if completed.returncode != 0:
        raise ValidationError("keychain password lookup failed")
    password = completed.stdout.decode("utf-8", errors="strict").rstrip("\n")
    if not password:
        raise ValidationError("keychain password is empty")
    return password


def connect(account: Account, password: str) -> imaplib.IMAP4:
    socket.setdefaulttimeout(25)
    try:
        if account.security != "tls":
            raise ValidationError("only tls accounts are supported by this validation")
        context = ssl.create_default_context()
        imap = imaplib.IMAP4_SSL(account.host, account.port, ssl_context=context)
        imap.login(account.username, password)
        return imap
    except (imaplib.IMAP4.error, OSError, ssl.SSLError, socket.timeout) as exc:
        raise ValidationError("imap login or connection failed") from exc


def snapshot(account: Account, password: str, target_uid: bytes | None) -> Snapshot:
    imap = connect(account, password)
    try:
        typ, data = imap.select("INBOX", readonly=True)
        if typ != "OK":
            raise ValidationError("imap readonly select failed")
        exists = int(data[0] or b"0")
        uidvalidity = response_value(imap, "UIDVALIDITY")
        uidnext = response_value(imap, "UIDNEXT")
        all_uids = uid_search(imap, "ALL")
        unseen = len(uid_search(imap, "UNSEEN"))
        sampled = all_uids[-MAX_MESSAGES_FOR_FLAGS:]
        target_flags_hash = ""
        if target_uid is not None:
            target_flags_hash = flags_hash(imap, [target_uid])
        return Snapshot(
            uidvalidity=uidvalidity,
            uidnext=uidnext,
            exists=exists,
            unseen=unseen,
            membership_hash=hash_items(all_uids),
            sampled_flags_hash=flags_hash(imap, sampled),
            target_flags_hash=target_flags_hash,
        )
    finally:
        try:
            imap.close()
        except Exception:
            pass
        try:
            imap.logout()
        except Exception:
            pass


def newest_uid(account: Account, password: str) -> bytes | None:
    imap = connect(account, password)
    try:
        typ, _ = imap.select("INBOX", readonly=True)
        if typ != "OK":
            raise ValidationError("imap readonly select failed")
        uids = uid_search(imap, "ALL")
        return uids[-1] if uids else None
    finally:
        try:
            imap.close()
        except Exception:
            pass
        try:
            imap.logout()
        except Exception:
            pass


def response_value(imap: imaplib.IMAP4, code: str) -> str:
    typ, data = imap.response(code)
    if typ != "OK" or not data or data[0] is None:
        return ""
    return data[0].decode("ascii", errors="replace")


def uid_search(imap: imaplib.IMAP4, criterion: str) -> list[bytes]:
    typ, data = imap.uid("search", None, criterion)
    if typ != "OK":
        raise ValidationError("imap uid search failed")
    if not data or not data[0]:
        return []
    return data[0].split()


def flags_hash(imap: imaplib.IMAP4, uids: list[bytes]) -> str:
    if not uids:
        return hash_items([])
    chunks: list[bytes] = []
    typ, data = imap.uid("fetch", b",".join(uids), "(FLAGS)")
    if typ != "OK":
        raise ValidationError("imap flag fetch failed")
    for item in data:
        if isinstance(item, tuple):
            chunks.append(hashlib.sha256(item[0] + b" " + item[1]).hexdigest().encode("ascii"))
        elif isinstance(item, bytes) and item.strip():
            chunks.append(hashlib.sha256(item).hexdigest().encode("ascii"))
    return hash_items(chunks)


def hash_items(items: list[bytes]) -> str:
    digest = hashlib.sha256()
    for item in items:
        digest.update(item)
        digest.update(b"\0")
    return digest.hexdigest()


def message_handle(account_id: str, mailbox: str, uidvalidity: str, uid: bytes) -> str:
    return ".".join(
        [
            b64url(account_id),
            b64url(mailbox),
            uidvalidity,
            uid.decode("ascii", errors="strict"),
        ]
    )


def b64url(value: str) -> str:
    return base64.urlsafe_b64encode(value.encode("utf-8")).decode("ascii").rstrip("=")


def compare_snapshots(before: Snapshot, after: Snapshot) -> None:
    if before.uidvalidity != after.uidvalidity:
        raise ValidationError("imap uidvalidity changed during validation")
    if before.uidnext != after.uidnext:
        raise ValidationError("imap uidnext changed during validation")
    if before.exists != after.exists:
        raise ValidationError("imap message count changed during validation")
    if before.unseen != after.unseen:
        raise ValidationError("imap unseen count changed during validation")
    if before.membership_hash != after.membership_hash:
        raise ValidationError("imap membership changed during validation")
    if before.sampled_flags_hash != after.sampled_flags_hash:
        raise ValidationError("imap sampled flags changed during validation")
    if after.target_flags_hash and before.target_flags_hash and before.target_flags_hash != after.target_flags_hash:
        raise ValidationError("imap target flags changed during validation")


def safe_reason(error: Exception) -> str:
    text = str(error) or error.__class__.__name__
    text = re.sub(r"[\w.+-]+@[\w.-]+", "[account]", text)
    text = re.sub(r"[A-Za-z0-9+/=_-]{16,}", "[token]", text)
    return text[:160]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("result=INTERRUPTED")
        sys.exit(130)
