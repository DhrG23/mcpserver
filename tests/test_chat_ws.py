"""server.md section 10 acceptance tests, run in-process with the scripted 'echo' model."""
import pytest
from starlette.websockets import WebSocketDisconnect


def connect(client, token):
    return client.websocket_connect("/chat/ws", headers={"Authorization": f"Bearer {token}"})


def until(ws, kind):
    frames = []
    while True:
        f = ws.receive_json()
        frames.append(f)
        if f["type"] == kind:
            return frames


def send(ws, cid, text="hello"):
    ws.send_json({"type": "chat.send", "client_id": cid, "text": text, "sent_at": "2026-10-04T10:00:00Z"})


def test_1_unauthenticated_upgrade_refused(client):
    with pytest.raises(Exception) as ei:
        with client.websocket_connect("/chat/ws"):
            pass
    assert getattr(ei.value, "status_code", 403) in (401, 403)


def test_token_in_query_string_is_not_accepted(client, token):
    with pytest.raises(Exception):
        with client.websocket_connect(f"/chat/ws?token={token}"):
            pass


def test_2_to_7_chat_flow(client, token):
    with connect(client, token) as ws:
        ready = ws.receive_json()
        assert ready["type"] == "ready" and ready["max_message_chars"] == 4000 and ready["protocol_version"] == 1

        ws.send_json({"type": "history.get", "limit": 50})
        assert until(ws, "history")

        send(ws, "t1")                                              # 2. ack -> start -> delta -> end
        frames = until(ws, "assistant.end")
        kinds = [f["type"] for f in frames]
        assert kinds[0] == "chat.ack" and kinds[1] == "assistant.start" and "assistant.delta" in kinds
        seqs = [f["seq"] for f in frames if f["type"] == "assistant.delta"]
        assert seqs == sorted(set(seqs)) and seqs[0] == 1
        assert frames[-1]["finish_reason"] == "stop" and "Echo: hello" in frames[-1]["text"]

        send(ws, "t1")                                              # 3. duplicate -> ack only
        ws.send_json({"type": "history.get", "limit": 50})
        frames = until(ws, "history")
        assert [f["type"] for f in frames] == ["chat.ack", "history"]
        assert [m["id"] for m in frames[-1]["messages"]].count("t1") == 1

        send(ws, "t3", "x" * 5000)                                  # 4. too long
        err = ws.receive_json()
        assert err["type"] == "error" and err["code"] == "message_too_long" and err["client_id"] == "t3"

        send(ws, "t2", "word " * 60)                                # 5. cancel
        ws.send_json({"type": "chat.cancel", "reply_to": "t2"})
        assert until(ws, "assistant.end")[-1]["finish_reason"] == "cancelled"

        ws.send_json({"type": "nope"})                              # 7. unknown frame, socket stays open
        assert ws.receive_json()["code"] == "invalid_frame"
        ws.send_json({"type": "history.get", "limit": 1})
        assert ws.receive_json()["type"] == "history"


def test_6_location_needs_approval_and_leaks_nothing(client, token):
    with connect(client, token) as ws:
        ws.receive_json()
        send(ws, "loc1", "where is my phone? share its location")
        frames = until(ws, "assistant.end")
        statuses = [f for f in frames if f["type"] == "tool.status"]
        assert any(f["state"] == "approval_required" and f["name"] == "get_location" for f in statuses)
        blob = str(frames)
        assert "'lat'" not in blob and "'lon'" not in blob and "1.5" not in blob


def test_other_users_cannot_see_my_chat(client, token, other_token):
    with connect(client, token) as ws:
        ws.receive_json()
        send(ws, "private1", "secret-note")
        until(ws, "assistant.end")
    with connect(client, other_token) as ws2:
        ws2.receive_json()
        ws2.send_json({"type": "history.get", "limit": 50})
        assert "private1" not in str(until(ws2, "history"))
        send(ws2, "private1", "i am someone else")                  # id collision must not leak or overwrite
        assert ws2.receive_json()["code"] == "invalid_frame"


def test_8_logout_closes_socket_with_4401(client):
    r = client.post("/auth/register", json={"email": "temp@example.com", "password": "longenough1"})
    tok = r.json()["token"]
    with connect(client, tok) as ws:
        ws.receive_json()
        client.post("/auth/logout", headers={"Authorization": f"Bearer {tok}"})
        with pytest.raises(WebSocketDisconnect) as ei:
            ws.receive_json()
        assert ei.value.code == 4401
