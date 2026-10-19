import os
import time
import uuid
import shutil
import threading
from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import JSONResponse
from pydantic import BaseModel

try:
    import libtorrent as lt
except Exception as e:
    lt = None
    print("libtorrent 不可用:", e)

app = FastAPI(title="magnet-stream")

DATA = os.environ.get("DATA_DIR", "/data")
HLS_DIR = os.environ.get("HLS_DIR", "/data/hls")
SESSION = {}
LOCK = threading.Lock()

os.makedirs(DATA, exist_ok=True)
os.makedirs(HLS_DIR, exist_ok=True)

app.mount("/hls", StaticFiles(directory=HLS_DIR), name="hls")


class ParseReq(BaseModel):
    magnet: str


class StreamReq(BaseModel):
    magnet: str
    index: int = 0


def _safe_parse(magnet: str):
    """解析磁力链接，返回 (name, files) ，files 为 [{index, name, size}]"""
    if lt is None:
        raise HTTPException(500, "后端未安装 libtorrent")
    ses = lt.session({"listen_interfaces": "0.0.0.0:6881"})
    params = lt.parse_magnet_uri(magnet)
    params.save_path = DATA
    h = ses.add_torrent(params)

    deadline = time.time() + 120
    while not h.has_metadata() and time.time() < deadline:
        time.sleep(0.5)

    if not h.has_metadata():
        raise HTTPException(504, "获取种子元数据超时（可能缺少做种者）")

    ti = h.get_torrent_info()
    files = []
    if hasattr(ti, "num_files"):
        n = ti.num_files()
        for i in range(n):
            try:
                f = ti.file_at(i)
                path = f.path if hasattr(f, "path") else str(i)
                size = f.size if hasattr(f, "size") else 0
            except Exception:
                path = f"file_{i}"
                size = 0
            files.append({"index": i, "name": path, "size": int(size)})
    return ti.name(), files, ses, h


@app.post("/api/parse")
def api_parse(req: ParseReq):
    try:
        name, files, ses, h = _safe_parse(req.magnet)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(400, str(e))

    sid = uuid.uuid4().hex
    with LOCK:
        SESSION[sid] = {"ses": ses, "h": h, "magnet": req.magnet, "name": name}
    return JSONResponse({"name": name, "files": files, "session": sid})


def _to_hls(src: str, out_dir: str):
    """用 ffmpeg 将 src 转成 HLS 分片"""
    os.makedirs(out_dir, exist_ok=True)
    playlist = os.path.join(out_dir, "index.m3u8")
    cmd = [
        "ffmpeg", "-y", "-i", src,
        "-c:v", "libx264", "-c:a", "aac",
        "-preset", "veryfast", "-crf", "24",
        "-hls_time", "6", "-hls_list_size", "0",
        "-hls_segment_filename", os.path.join(out_dir, "seg_%05d.ts"),
        playlist,
    ]
    proc = subprocess_run(cmd)
    if proc != 0:
        raise RuntimeError("ffmpeg 转码失败")
    return playlist


def subprocess_run(cmd):
    import subprocess
    p = subprocess.run(cmd, capture_output=True, text=True)
    print("CMD:", " ".join(cmd))
    if p.returncode != 0:
        print("STDERR:", p.stderr[-2000:])
    return p.returncode


@app.post("/api/stream")
def api_stream(req: StreamReq):
    # 优先复用已解析的会话；否则重新解析
    sid = req.magnet[:64]
    with LOCK:
        rec = None
        for v in SESSION.values():
            if v["magnet"] == req.magnet:
                rec = v
                break

    if rec is None:
        try:
            name, files, ses, h = _safe_parse(req.magnet)
            rec = {"ses": ses, "h": h, "magnet": req.magnet, "name": name}
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(400, str(e))
        with LOCK:
            SESSION[uuid.uuid4().hex] = rec

    h = rec["h"]
    ti = h.get_torrent_info()
    if req.index >= (ti.num_files() if hasattr(ti, "num_files") else 0):
        raise HTTPException(404, "文件序号不存在")

    # 只下载选中文件
    prio = [0] * (ti.num_files() if hasattr(ti, "num_files") else 0)
    prio[req.index] = 7
    h.prioritize_files(prio)

    # 等待下载到足够进度
    deadline = time.time() + 3600
    target = ti.files().file_size(req.index) if hasattr(ti, "files") else 0
    download_path = os.path.join(DATA, ti.files().file_path(req.index) if hasattr(ti, "files") else str(req.index))
    while time.time() < deadline:
        s = h.status()
        if s.is_seeding or (target and s.total_done >= target * 0.98):
            break
        time.sleep(1)

    out_dir = os.path.join(HLS_DIR, uuid.uuid4().hex)
    playlist = _to_hls(download_path, out_dir)
    rel = os.path.relpath(playlist, HLS_DIR)
    url = f"/hls/{rel}"
    return JSONResponse({"hlsURL": url})


@app.get("/health")
def health():
    return {"ok": True, "libtorrent": lt is not None}