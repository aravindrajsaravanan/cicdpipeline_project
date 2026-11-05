from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_home_page_renders_form():
    response = client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
    assert "aravind is a devops engineer" in response.text


def test_health_endpoint():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_unknown_path_returns_404():
    assert client.get("/does-not-exist").status_code == 404
