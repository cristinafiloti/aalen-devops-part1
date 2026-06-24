"""
FastAPI application for Project Work Part II.

Two HTML pages plus a small JSON health endpoint:

    GET  /              - Web Page 1: lists every blob in the "images" container,
                          shows a download link for each, plus a link to /upload
    GET  /upload        - Web Page 2: HTML form to upload a new image/file
    POST /upload        - handles the form submission, streams the file to the
                          storage container, then redirects back to /
    GET  /download/{n}  - generates a short-lived SAS URL for a blob and
                          redirects the browser to it (the user gets the file
                          directly from Azure Storage, not through the app)
    GET  /healthz       - liveness probe used by App Service

Authentication
--------------
All Azure calls use ``DefaultAzureCredential`` which, inside an App Service
with a system-assigned managed identity, automatically picks up the MI token
through IMDS. No connection strings or account keys are ever read by this
process. The storage connection string is still kept in Key Vault as a
fallback but the running app never touches it.
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import List

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from azure.identity import DefaultAzureCredential
from azure.storage.blob import (
    BlobServiceClient,
    BlobSasPermissions,
    UserDelegationKey,
    generate_blob_sas,
)
from azure.keyvault.secrets import SecretClient
from azure.core.exceptions import AzureError, ResourceNotFoundError

# ---------------------------------------------------------------------------
# Configuration – every value comes from app settings, never hard-coded.
# ---------------------------------------------------------------------------

KEY_VAULT_NAME = os.environ["KEY_VAULT_NAME"]
STORAGE_ACCOUNT_NAME = os.environ["STORAGE_ACCOUNT_NAME"]
IMAGES_CONTAINER_NAME = os.environ.get("IMAGES_CONTAINER_NAME", "images")
MAX_UPLOAD_MB = int(os.environ.get("MAX_UPLOAD_MB", "10"))
MAX_UPLOAD_BYTES = MAX_UPLOAD_MB * 1024 * 1024

# File extensions accepted by the form. Kept permissive for the lab.
ALLOWED_EXTENSIONS = {
    ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg",
    ".pdf", ".txt", ".csv", ".json",
}

KEY_VAULT_URL = f"https://{KEY_VAULT_NAME}.vault.azure.net"
STORAGE_ACCOUNT_URL = f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net"

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("app")

# ---------------------------------------------------------------------------
# Azure clients – one credential, reused.
# ---------------------------------------------------------------------------

credential = DefaultAzureCredential()
blob_service = BlobServiceClient(account_url=STORAGE_ACCOUNT_URL, credential=credential)
container_client = blob_service.get_container_client(IMAGES_CONTAINER_NAME)
secret_client = SecretClient(vault_url=KEY_VAULT_URL, credential=credential)

# User-delegation key for SAS URLs is cached and refreshed every 50 minutes.
_user_delegation_key: UserDelegationKey | None = None
_user_delegation_key_expiry: datetime | None = None


def _get_user_delegation_key() -> UserDelegationKey:
    """Return a cached user-delegation key, refreshing it shortly before it expires."""
    global _user_delegation_key, _user_delegation_key_expiry
    now = datetime.now(timezone.utc)
    if (
        _user_delegation_key is None
        or _user_delegation_key_expiry is None
        or _user_delegation_key_expiry - now < timedelta(minutes=10)
    ):
        start = now - timedelta(minutes=5)
        expiry = now + timedelta(hours=1)
        _user_delegation_key = blob_service.get_user_delegation_key(start, expiry)
        _user_delegation_key_expiry = expiry
        log.info("Refreshed user-delegation key, valid until %s", expiry.isoformat())
    return _user_delegation_key


def _build_download_sas_url(blob_name: str) -> str:
    """Return a HTTPS URL that lets the browser download a single blob for 15 minutes."""
    udk = _get_user_delegation_key()
    sas = generate_blob_sas(
        account_name=STORAGE_ACCOUNT_NAME,
        container_name=IMAGES_CONTAINER_NAME,
        blob_name=blob_name,
        user_delegation_key=udk,
        permission=BlobSasPermissions(read=True),
        expiry=datetime.now(timezone.utc) + timedelta(minutes=15),
    )
    return f"{STORAGE_ACCOUNT_URL}/{IMAGES_CONTAINER_NAME}/{blob_name}?{sas}"


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

BASE_DIR = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

app = FastAPI(
    title="Aalen Project Work – Part II",
    description="FastAPI demo: image storage on Azure with managed identity + Key Vault.",
    version="1.0.0",
)
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")


@app.on_event("startup")
def _startup_log() -> None:
    """Fail fast on start-up if the configuration is wrong."""
    log.info("Starting up. Vault=%s Storage=%s Container=%s",
             KEY_VAULT_NAME, STORAGE_ACCOUNT_NAME, IMAGES_CONTAINER_NAME)
    try:
        secret_client.get_secret("AppSecret")
        log.info("Successfully read AppSecret from Key Vault.")
    except ResourceNotFoundError:
        log.warning("Secret 'AppSecret' not present in Key Vault.")
    except AzureError as exc:
        log.warning("Could not reach Key Vault on startup: %s", exc)


# ---------- Web Page 1: list blobs ----------------------------------------------------

@app.get("/", response_class=HTMLResponse)
def page_list(request: Request, msg: str | None = None) -> HTMLResponse:
    try:
        blobs = list(container_client.list_blobs())
    except AzureError as exc:
        log.exception("Listing blobs failed")
        raise HTTPException(status_code=502, detail=f"Storage error: {exc}") from exc

    items = []
    for b in sorted(blobs, key=lambda x: x.last_modified or datetime.min, reverse=True):
        items.append({
            "name": b.name,
            "size_kb": round((b.size or 0) / 1024, 1),
            "modified": b.last_modified.strftime("%Y-%m-%d %H:%M UTC") if b.last_modified else "-",
        })

    return templates.TemplateResponse(
        "list.html",
        {
            "request": request,
            "items": items,
            "msg": msg,
            "container": IMAGES_CONTAINER_NAME,
            "account": STORAGE_ACCOUNT_NAME,
        },
    )


# ---------- Download via SAS redirect -------------------------------------------------

@app.get("/download/{blob_name:path}")
def download(blob_name: str) -> RedirectResponse:
    # Reject path traversal etc.
    if "/" in blob_name or "\\" in blob_name or ".." in blob_name:
        raise HTTPException(status_code=400, detail="Invalid blob name.")

    try:
        if not container_client.get_blob_client(blob_name).exists():
            raise HTTPException(status_code=404, detail="Blob not found.")
        url = _build_download_sas_url(blob_name)
    except AzureError as exc:
        log.exception("Failed to build SAS URL")
        raise HTTPException(status_code=502, detail=f"Storage error: {exc}") from exc

    return RedirectResponse(url=url, status_code=302)


# ---------- Web Page 2: upload form ---------------------------------------------------

@app.get("/upload", response_class=HTMLResponse)
def page_upload(request: Request) -> HTMLResponse:
    return templates.TemplateResponse(
        "upload.html",
        {
            "request": request,
            "max_mb": MAX_UPLOAD_MB,
            "allowed": ", ".join(sorted(ALLOWED_EXTENSIONS)),
        },
    )


@app.post("/upload")
async def upload_post(
    file: UploadFile = File(...),
    custom_name: str = Form(""),
) -> RedirectResponse:
    if file.filename is None or file.filename.strip() == "":
        raise HTTPException(status_code=400, detail="No file selected.")

    ext = Path(file.filename).suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail=f"Extension '{ext}' not allowed. Allowed: {sorted(ALLOWED_EXTENSIONS)}",
        )

    # Sanitise final blob name.
    raw_name = custom_name.strip() or Path(file.filename).stem
    safe_stem = "".join(c for c in raw_name if c.isalnum() or c in "-_.").strip("._-")
    if not safe_stem:
        safe_stem = "upload"
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    blob_name = f"{stamp}-{safe_stem}{ext}"

    # Stream-read the file but enforce a hard cap.
    data = await file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File exceeds {MAX_UPLOAD_MB} MB limit.",
        )

    try:
        container_client.upload_blob(
            name=blob_name,
            data=data,
            overwrite=False,
            content_type=file.content_type or "application/octet-stream",
        )
    except AzureError as exc:
        log.exception("Upload failed")
        raise HTTPException(status_code=502, detail=f"Storage error: {exc}") from exc

    log.info("Uploaded blob %s (%d bytes)", blob_name, len(data))
    return RedirectResponse(url=f"/?msg=Uploaded+{blob_name}", status_code=303)


# ---------- Health probe --------------------------------------------------------------

@app.get("/healthz")
def healthz() -> JSONResponse:
    return JSONResponse({"status": "ok"})
