# Run locally: uvicorn main:app --reload
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.templating import Jinja2Templates

# Templates live next to this file (/code inside the container, the repo root locally).
BASE_DIR = Path(__file__).resolve().parent

app = FastAPI()
templates = Jinja2Templates(directory=BASE_DIR)


@app.get("/")
def form_post(request: Request):
    return templates.TemplateResponse(request, "form.html")


@app.get("/health")
def health():
    return {"status": "ok"}
