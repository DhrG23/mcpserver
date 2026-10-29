def test_register_login_me_logout(client):
    r = client.post("/auth/register", json={"email": "a@example.com", "password": "longenough1"})
    assert r.status_code == 200 and r.json()["user_name"] == "a"
    assert client.post("/auth/register", json={"email": "A@example.com", "password": "longenough1"}).status_code == 409
    assert client.post("/auth/register", json={"email": "b@example.com", "password": "short"}).status_code == 422
    login = client.post("/auth/login", json={"email": "a@example.com", "password": "longenough1"})
    assert login.status_code == 200
    tok = login.json()["token"]
    assert client.get("/auth/me", headers={"Authorization": f"Bearer {tok}"}).json()["user_name"] == "a"
    assert client.post("/auth/logout", headers={"Authorization": f"Bearer {tok}"}).status_code == 200
    assert client.get("/auth/me", headers={"Authorization": f"Bearer {tok}"}).status_code == 401


def test_bad_password_and_error_shape(client):
    r = client.post("/auth/login", json={"email": "nobody@example.com", "password": "whatever123"})
    assert r.status_code == 401 and isinstance(r.json()["detail"], str)
    r = client.post("/auth/login", json={"email": "x"})              # missing password -> still {"detail": "<string>"}
    assert r.status_code == 422 and isinstance(r.json()["detail"], str)


def test_login_throttle(client):
    for _ in range(5):
        client.post("/auth/login", json={"email": "victim@example.com", "password": "wrong-password"})
    assert client.post("/auth/login", json={"email": "victim@example.com", "password": "wrong-password"}).status_code == 429


def test_heartbeat_devices_are_user_scoped(client, token, other_token):
    h = {"Authorization": f"Bearer {token}"}
    snap = {"schema_version": 4, "device_id": "iphone-1", "device_name": "iPhone", "platform": "ios",
            "battery": {"level": 82}, "location": {"lat": 1.5, "lon": 2.5}}
    r = client.post("/heartbeat", json=snap, headers=h)
    assert r.status_code == 200 and r.json()["pending_commands"] == []
    dev_id = r.json()["device_id"]
    mine = client.get("/devices", headers=h).json()
    assert [d["name"] for d in mine] == ["iPhone"] and mine[0]["last_battery"] == 82
    other = {"Authorization": f"Bearer {other_token}"}
    assert client.get("/devices", headers=other).json() == []
    assert client.get(f"/devices/{dev_id}", headers=other).status_code == 404
    assert client.delete(f"/devices/{dev_id}", headers=other).status_code == 404
    assert client.get("/devices").status_code == 401                       # no anonymous listing any more
    assert client.patch(f"/devices/{dev_id}", json={"name": "Pocket"}, headers=h).json()["name"] == "Pocket"
    cmd = client.post(f"/devices/{dev_id}/commands", json={"kind": "notification", "payload": {"title": "hi"}}, headers=h)
    assert cmd.status_code == 200
    assert client.post("/heartbeat", json=snap, headers=h).json()["pending_commands"][0]["kind"] == "notification"
    assert client.post(f"/devices/{dev_id}/commands", json={"kind": "rm -rf"}, headers=h).status_code == 422


def test_approvals_need_auth(client):
    assert client.get("/approvals").status_code == 401
    assert client.get("/approvals", headers={"Authorization": "Bearer t-admin"}).status_code == 200
