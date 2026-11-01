"""Local CPU cover service. Model inference runs in a cancellable child process.

The public Skill API accepts library IDs and fixed actions, not shell commands,
arbitrary file paths, arbitrary URLs, or access to QQ/AI credentials.
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time
import uuid
from urllib.parse import parse_qs, urlsplit

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse, JSONResponse, HTMLResponse

from pipeline import BASE_MODELS, inside
from music import search_qq_music, selected_index

MAX_UPLOAD = 256 * 1024 * 1024
AUDIO_EXTENSIONS = {".wav", ".mp3", ".m4a", ".ogg", ".flac", ".aac"}
STAGES = {"queued": "等待处理", "starting": "启动中", "normalizing": "读取歌曲",
          "downloading": "下载歌曲",
          "separating": "分离人声与伴奏", "converting": "转换音色", "mixing": "混合伴奏",
          "completed": "已完成", "failed": "失败", "cancelled": "已取消"}


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def package_version(name):
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return ""


def file_id(name):
    return hashlib.sha256(name.encode("utf-8")).hexdigest()[:24]


class CoverService:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        for name in ("songs", "models", "outputs", "jobs", "logs", "tmp", "cache"):
            (self.root / name).mkdir(exist_ok=True)
        self.config = json.loads((self.root / "config.json").read_text(encoding="utf-8-sig"))
        self.lock = threading.RLock()
        self.jobs = {}
        self.processes = {}
        self.searches = {}
        # A server restart must not leave an old job falsely marked running.
        for file in (self.root / "jobs").glob("*/state.json"):
            try:
                job = json.loads(file.read_text(encoding="utf-8"))
                if job.get("status") in {"queued", "running"}:
                    job.update(status="failed", stage="failed", message="服务已重启，原任务已停止")
                if re.fullmatch(r"[a-f0-9]{32}", job.get("id", "")):
                    self.jobs[job["id"]] = job
                    self.save(job)
            except (OSError, ValueError, KeyError):
                continue

    def save(self, job):
        folder = inside(self.root / "jobs", job["id"])
        folder.mkdir(exist_ok=True)
        target = folder / "state.json"
        temp = folder / "state.tmp"
        temp.write_text(json.dumps(job, ensure_ascii=False, indent=2), encoding="utf-8")
        temp.replace(target)

    def library(self, category):
        root = self.root / category
        suffixes = AUDIO_EXTENSIONS if category == "songs" else {".pth"}
        result = []
        for file in sorted(root.glob("*")):
            if file.is_symlink() or not file.is_file() or file.suffix.lower() not in suffixes:
                continue
            result.append({"id": file_id(file.name), "name": file.name, "size": file.stat().st_size})
        return result

    def health(self):
        dependencies = {name: package_version(name) for name in ("torch", "torchaudio", "demucs", "rvc-python", "fairseq", "numpy")}
        spec = importlib.util.find_spec("rvc_python")
        base = (Path(spec.origin).parent / "base_model") if spec and spec.origin else self.root / "missing-base-models"
        missing = [name for name, (size, _) in BASE_MODELS.items()
                   if not (base / name).is_file() or (base / name).stat().st_size != size]
        if not Path(self.config.get("ffmpeg", "")).is_file():
            missing.append("ffmpeg")
        missing.extend(name for name, version in dependencies.items() if not version)
        if not self.library("models"):
            missing.append("RVC 音色模型：在本地网页导入 .pth，或放入 models 目录")
        return {"ok": True, "service": "QQM Local RVC Cover", "version": "1.1.0",
                "instanceId": self.config.get("instanceId", ""),
                "device": "cpu", "dependencies": dependencies,
                "canCover": not missing, "missing": missing,
                "models": self.library("models"), "songs": self.library("songs"),
                "message": "翻唱环境已就绪" if not missing else "环境已连接，仍有缺项：" + "；".join(missing)}

    def find_file(self, category, value):
        entry = next((row for row in self.library(category)
                      if row["id"] == value or row["name"] == value), None)
        if not entry:
            raise ValueError("歌曲或音色不存在，请先列出歌曲 / 音色并使用返回的 ID")
        return entry["name"]

    @staticmethod
    def scope(value):
        if not isinstance(value, str) or not value.strip() or len(value) > 2000:
            raise ValueError("缺少当前会话标识")
        return hashlib.sha256(value.encode("utf-8")).hexdigest()

    def public_job(self, job):
        return {key: job.get(key) for key in ("id", "type", "status", "stage", "message", "song", "song_id", "model", "created", "finished")}

    @staticmethod
    def song_mid(value):
        value = str(value).strip()
        if len(value) > 2048:
            raise ValueError("歌曲链接过长")
        if value.startswith(("https://", "http://")):
            url = urlsplit(value)
            if url.hostname not in {"y.qq.com", "c.y.qq.com", "i.y.qq.com"}:
                raise ValueError("请提供QQ音乐歌曲详情链接或歌曲MID，不读取其他网址")
            query = parse_qs(url.query)
            value = (query.get("songmid") or query.get("mid") or [""])[0]
            if not value:
                match = re.search(r"/(?:songDetail|song)/([A-Za-z0-9]{10,20})(?:\.html)?(?:/|$)", url.path)
                value = match.group(1) if match else ""
        if not re.fullmatch(r"[A-Za-z0-9]{10,20}", value):
            raise ValueError("无法识别歌曲MID。请提供QQ音乐歌曲详情页链接；短分享链接需先打开复制详情链接")
        return value

    def requester(self, body):
        scope = self.scope(body.get("scope"))
        if body.get("scope") == "desktop":
            return scope, {}, True
        caller = body.get("caller")
        if not isinstance(caller, dict) or any(not isinstance(caller.get(key), str) or
                not caller[key].strip() for key in ("id", "messageId")) or not isinstance(caller.get("text"), str):
            raise ValueError("需要新版管理器提供本条消息的提问者信息，请安装支持接口7的客户端")
        if len(caller["id"]) > 512 or len(caller["messageId"]) > 512 or len(caller["text"]) > 16000:
            raise ValueError("当前消息过长，请简短说明要选哪个版本")
        return self.scope(body["scope"] + "|asker:" + caller["id"]), caller, False

    def prune_searches(self):
        for key in list(self.searches):
            if self.searches[key]["expires"] <= time.monotonic():
                del self.searches[key]
        while len(self.searches) > 128:
            del self.searches[next(iter(self.searches))]

    def search_reply(self, entry):
        if entry.get("result"):
            return entry["result"]
        choices = [{**row, "number": i + 1} for i, row in enumerate(entry["candidates"])]
        name = re.sub(r"[\r\n]", "", str(entry.get("name", "")))[:80] or "提问的朋友"
        lines = [f"{name}，找到以下歌曲版本："]
        lines.extend(f"{row['number']}. {row['name']} — {row['singer']}" for row in choices)
        multiple = len(choices) > 1
        lines.append("请你回复“选1”“选2”或歌手名，确认后再导入。列表保留20分钟；其他群友的回复不会替你选择。"
                     if multiple else "仅找到这一个候选，可调用确认导入工具继续。")
        return {"ok": True, "status": "needs_selection" if multiple else "single_candidate",
                "search_id": entry["id"], "query": entry["query"], "candidates": choices,
                "needs_selection": multiple, "requester_name": name,
                "message": "\n".join(lines)}

    def search_music(self, body):
        key, caller, desktop = self.requester(body)
        query = str(body.get("args", {}).get("query", "")).strip()
        if not query or len(query) > 100:
            raise ValueError("请提供100字以内的歌名，可加歌手或版本缩小范围")
        with self.lock:
            self.prune_searches()
            entry = self.searches.get(key)
            # The model cannot evade an ambiguous search by rephrasing the query
            # and picking a different single result in the same user turn.
            if entry and not desktop and entry["messageId"] == caller["messageId"]:
                return self.search_reply(entry)
            if entry and not desktop and not entry.get("result") and selected_index(caller["text"], entry["candidates"]) is not None:
                return self.search_reply(entry)
        candidates = search_qq_music(query)
        if not candidates:
            with self.lock:
                self.searches.pop(key, None)
            return {"ok": True, "status": "not_found", "candidates": [],
                    "message": "没有找到这首歌，请补充歌手或歌曲版本后重试。无需自己找链接。"}
        entry = {"id": uuid.uuid4().hex, "query": query, "candidates": candidates,
                 "messageId": caller.get("messageId", ""), "name": caller.get("name", ""),
                 "expires": time.monotonic() + 20 * 60}
        with self.lock:
            existing = self.searches.get(key)
            if existing and not desktop and existing["messageId"] == caller["messageId"]:
                return self.search_reply(existing)
            self.searches[key] = entry
            self.prune_searches()
        return self.search_reply(entry)

    def select_music(self, body, scope, expected_mid=None):
        key, caller, desktop = self.requester(body)
        args = body.get("args", {})
        with self.lock:
            self.prune_searches()
            entry = self.searches.get(key)
            if not entry or entry["id"] != args.get("search_id", entry["id"] if not desktop else None):
                raise ValueError("当前提问者没有这份候选列表，或列表已过期；请重新搜索歌名")
            if entry.get("result"):
                return entry["result"]
            if desktop:
                choice = args.get("choice")
                index = choice - 1 if type(choice) is int and 1 <= choice <= len(entry["candidates"]) else None
            elif len(entry["candidates"]) == 1:
                index = 0
            else:
                if caller["messageId"] == entry["messageId"]:
                    raise ValueError("有多个歌曲版本，需要先把候选列表回复给原提问者；等他的新消息选择，不能自行选")
                index = selected_index(caller["text"], entry["candidates"])
            if index is None:
                raise ValueError("尚未收到原提问者的明确选择，请回复“选1”“选2”或唯一的歌手名")
            candidate = entry["candidates"][index]
            if expected_mid and candidate["mid"] != expected_mid:
                raise ValueError("歌曲MID与原提问者实际选择不一致，请按用户选择的版本处理")
            result = self.import_music({"song": candidate["mid"]}, scope)
            result["selected"] = candidate
            entry["result"] = result
            return result

    def import_requested_music(self, body, scope):
        key, caller, desktop = self.requester(body)
        mid = self.song_mid(body.get("args", {}).get("song", ""))
        if desktop or re.search(r"(?<![A-Za-z0-9])" + re.escape(mid) + r"(?![A-Za-z0-9])", caller["text"]):
            return self.import_music({"song": mid}, scope)
        with self.lock:
            self.prune_searches()
            entry = self.searches.get(key)
            if entry and any(row["mid"] == mid for row in entry["candidates"]):
                return self.select_music({**body, "args": {"search_id": entry["id"]}}, scope, expected_mid=mid)
        raise ValueError("当前用户未提供此歌曲链接；请先搜索歌名，有多个版本时让原提问者选择")

    def import_music(self, body, scope):
        mid = self.song_mid(body.get("song", ""))
        filename = f"QQ音乐-{mid}.mp3"
        if (self.root / "songs" / filename).exists():
            return {"ok":True, "message":"此歌曲已在歌曲目录，可直接选择它翻唱", "song_id":file_id(filename), "song":filename}
        with self.lock:
            if any(job["status"] in {"queued","running"} for job in self.jobs.values()):
                raise ValueError("正在处理其他任务，请完成后再导入")
            job={"id":uuid.uuid4().hex, "type":"import", "scope":scope, "mid":mid,
                 "status":"queued", "stage":"queued", "message":"歌曲导入已排队，尚未下载或翻唱",
                 "song":filename, "song_file":filename, "model":"QQ音乐导入", "created":utc_now(), "logs":[]}
            self.jobs[job["id"]]=job
            self.save(job)
        threading.Thread(target=self.run,args=(job,),daemon=True).start()
        return {"ok":True,"job":self.public_job(job),"message":"歌曲导入已提交，稍后查询状态；导入成功后再选择音色翻唱，不要重复提交"}

    def get_job(self, job_id, scope):
        with self.lock:
            if not job_id:
                matches = [job for job in self.jobs.values() if job["scope"] == scope]
                if not matches:
                    raise ValueError("当前会话还没有翻唱任务")
                return matches[-1]
            job = self.jobs.get(str(job_id))
            if not job or job.get("scope") != scope:
                raise ValueError("当前会话没有这个翻唱任务")
            return job

    def start(self, body, scope):
        missing = self.health()["missing"]
        if missing:
            raise ValueError("尚不能翻唱：" + "；".join(missing))
        song_file = self.find_file("songs", str(body.get("song", "")))
        model_file = self.find_file("models", str(body.get("model", "")))
        pitch, seconds, start = int(body.get("pitch", 0)), int(body.get("clip_seconds", 30)), float(body.get("clip_start", 0))
        if not -24 <= pitch <= 24 or not 5 <= seconds <= 60 or not 0 <= start <= 900:
            raise ValueError("升降调须为 -24–24，试听须为5–60秒，起点须为0–900秒")
        with self.lock:
            if any(job["status"] in {"queued", "running"} for job in self.jobs.values()):
                raise ValueError("CPU 正在处理其他任务，请完成后再开始")
            job = {"id": uuid.uuid4().hex, "type":"cover", "scope": scope, "status": "queued", "stage": "queued",
                   "message": "已接受任务，尚未生成音频", "song": song_file, "model": model_file,
                   "song_file": song_file, "model_file": model_file, "pitch": pitch,
                   "clip_seconds": seconds, "clip_start": start, "created": utc_now(), "logs": []}
            self.jobs[job["id"]] = job
            self.save(job)
        threading.Thread(target=self.run, args=(job,), daemon=True).start()
        return {"ok": True, "job": self.public_job(job),
                "message": "翻唱任务已提交，CPU处理可能需要较长时间。稍后查询状态，完成后调用发送成品；不要重复提交。"}

    def run(self, job):
        work = inside(self.root / "jobs", job["id"])
        request = work / "request.json"
        request.write_text(json.dumps(job, ensure_ascii=False), encoding="utf-8")
        env = dict(os.environ)
        env.update(TORCH_HOME=str(self.root / "cache" / "torch"),
                   TEMP=str(self.root / "tmp"), TMP=str(self.root / "tmp"),
                   NUMBA_CACHE_DIR=str(self.root / "cache" / "numba"),
                   OMP_NUM_THREADS="2", MKL_NUM_THREADS="2", OPENBLAS_NUM_THREADS="2",
                   PYTHONUNBUFFERED="1", PYTHONIOENCODING="utf-8")
        # The service never passes its parent's AI/QQ/Git credentials to jobs.
        for key in list(env):
            if re.search(r"TOKEN|SECRET|PASSWORD|API_KEY|ACCESS_KEY", key, re.I):
                env.pop(key, None)
        command = [sys.executable, str(Path(__file__).with_name("pipeline.py")),
                   "--root", str(self.root), "--job", f"{job['id']}/request.json"]
        try:
            with self.lock:
                if job["status"] == "cancelled":
                    return
                process = subprocess.Popen(command, cwd=str(work), env=env, stdin=subprocess.DEVNULL,
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                           encoding="utf-8", errors="replace", creationflags=(
                                               getattr(subprocess, "CREATE_NO_WINDOW", 0) |
                                               getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)),
                                           start_new_session=os.name != "nt")
                self.processes[job["id"]] = process
                job.update(status="running", stage="starting", message="正在启动 CPU 翻唱进程")
                self.save(job)
            with (work / "worker.log").open("w", encoding="utf-8") as log:
                for line in process.stdout:
                    log.write(line[:8000]); log.flush()
                    with self.lock:
                        job["logs"] = (job["logs"] + [line.strip()[-800:]])[-35:]
                        try:
                            event = json.loads(line)
                            stage = event.get("stage")
                            if event.get("event") == "stage" and stage in STAGES and job["status"] != "cancelled":
                                job.update(stage=stage, message=str(event.get("message", STAGES[stage]))[:1200])
                        except (ValueError, AttributeError):
                            pass
            code = process.wait()
            with self.lock:
                if job["status"] != "cancelled":
                    clip = self.root / "outputs" / job["id"] / "clip.mp3"
                    song_file = self.root / "songs" / job.get("song_file", "missing")
                    if code == 0 and job["stage"] == "completed" and job.get("type") == "import" and song_file.is_file() and song_file.stat().st_size > 100:
                        job.update(status="completed", message="QQ音乐歌曲已导入，可按返回的歌曲ID选择音色翻唱", song_id=file_id(song_file.name))
                    elif code == 0 and job["stage"] == "completed" and clip.is_file() and clip.stat().st_size > 100:
                        job.update(status="completed", stage="completed", message="翻唱完成，可发送试听或在本地网页下载整首")
                    else:
                        job.update(status="failed", stage="failed", message="翻唱失败：" + str(job.get("message", "请查看本地日志"))[-1000:])
                job["finished"] = utc_now()
                self.save(job)
        except Exception as error:
            with self.lock:
                job.update(status="failed", stage="failed", message=str(error)[-1000:], finished=utc_now())
                self.save(job)
        finally:
            with self.lock:
                self.processes.pop(job["id"], None)

    def cancel(self, job):
        with self.lock:
            if job["status"] not in {"queued", "running"}:
                return {"ok": True, "message": "任务已结束，不需要取消", "job": self.public_job(job)}
            process = self.processes.get(job["id"])
            if process and process.poll() is None:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), timeout=8)
                else:
                    os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    raise ValueError("尚未确认处理进程已停止，请查看本地日志，不要重复提交任务")
            job.update(status="cancelled", stage="cancelled", message="任务已取消", finished=utc_now())
            self.save(job)
            return {"ok": True, "message": "已取消当前会话的翻唱任务", "job": self.public_job(job)}

    def tool(self, body):
        scope = self.scope(body.get("scope"))
        action = body.get("action")
        args = body.get("args", {})
        if not isinstance(args, dict):
            raise ValueError("工具参数必须是对象")
        if action == "health":
            return self.health()
        if action in {"models", "songs"}:
            return {"ok": True, "items": self.library(action)}
        if action == "start":
            return self.start(args, scope)
        if action == "search_qq":
            return self.search_music(body)
        if action == "select_qq":
            return self.select_music(body, scope)
        if action == "import_qq":
            return self.import_requested_music(body, scope)
        job = self.get_job(args.get("job_id", ""), scope)
        if action == "status":
            return {"ok": True, "job": self.public_job(job)}
        if action == "cancel":
            return self.cancel(job)
        if action == "audio":
            if job["status"] != "completed" or job.get("type") == "import":
                raise ValueError("任务尚未成功完成，不能发送成品")
            audio = inside(self.root / "outputs", f"{job['id']}/clip.mp3")
            if not 100 < audio.stat().st_size <= 5 * 1024 * 1024:
                raise ValueError("试听文件为空或超过5 MB")
            return {"ok": True, "name": "翻唱试听.mp3", "audioBase64": base64.b64encode(audio.read_bytes()).decode("ascii")}
        raise ValueError("未知翻唱工具")


def create_app(root: Path, port: int = 23339):
    service = CoverService(root)
    app = FastAPI(title="QQ机器人管理器 · 本地翻唱", docs_url=None, redoc_url=None)
    app.state.cover = service
    authorities = {f"127.0.0.1:{port}", f"localhost:{port}"}

    @app.middleware("http")
    async def local_only(request: Request, call_next):
        if request.headers.get("host", "").lower() not in authorities:
            return JSONResponse({"error": "只接受本机入口"}, status_code=403)
        origin = request.headers.get("origin")
        if origin and origin not in {"http://" + host for host in authorities}:
            return JSONResponse({"error": "拒绝跨站请求"}, status_code=403)
        if request.method not in {"GET", "POST", "HEAD"}:
            return JSONResponse({"error": "不支持此请求方法"}, status_code=405)
        if request.method == "POST":
            if request.headers.get("x-qqm-cover") != "1":
                return JSONResponse({"error": "缺少本地调用标记"}, status_code=403)
            try:
                length = int(request.headers.get("content-length", "-1"))
            except ValueError:
                length = -1
            limit = MAX_UPLOAD + 1024 * 1024 if request.url.path == "/api/upload" else 65536
            if length < 0 or length > limit or request.headers.get("transfer-encoding"):
                return JSONResponse({"error": "请求体缺少长度或超过限制"}, status_code=413)
        return await call_next(request)

    @app.get("/", response_class=HTMLResponse)
    def home():
        return Path(__file__).with_name("web").joinpath("index.html").read_text(encoding="utf-8")

    @app.get("/api/health")
    def health():
        return service.health()

    @app.get("/api/jobs")
    def jobs():
        with service.lock:
            return {"jobs": [dict(service.public_job(job), logs=job.get("logs", []))
                             for job in list(service.jobs.values())[-30:]][::-1]}

    @app.post("/api/tool")
    async def tool(request: Request):
        try:
            body = await request.json()
            if not isinstance(body, dict):
                raise ValueError("参数必须是 JSON 对象")
            # Search may wait for its upstream. Keep health/status/UI responsive.
            # Long inference is still performed in a cancellable child job.
            return await run_in_threadpool(service.tool, body)
        except (ValueError, OSError, KeyError) as error:
            return {"ok": False, "isError": True, "message": str(error)[:1400]}

    @app.post("/api/upload")
    async def upload(kind: str, file: UploadFile = File(...)):
        if kind not in {"songs", "models"}:
            raise HTTPException(400, "不支持此素材类型")
        name = Path((file.filename or "").replace("\\", "/")).name
        allowed = AUDIO_EXTENSIONS if kind == "songs" else {".pth"}
        if Path(name).suffix.lower() not in allowed or not name or re.search(r'[<>:"/\\|?*\x00-\x1f]', name):
            raise HTTPException(400, "请选择音频或 RVC .pth 音色模型")
        if len(name) > 150:
            raise HTTPException(400, "文件名过长")
        destination = inside(root / kind, name)
        if destination.exists():
            raise HTTPException(409, "同名文件已存在，请先改名，不会覆盖原文件")
        temporary = inside(root / "tmp", uuid.uuid4().hex + ".upload")
        size = 0
        try:
            with temporary.open("xb") as output:
                while chunk := await file.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_UPLOAD:
                        raise HTTPException(413, "文件超过256 MB")
                    output.write(chunk)
            if size < 16:
                raise HTTPException(400, "文件为空或过小")
            with service.lock:
                if destination.exists():
                    raise HTTPException(409, "同名文件已存在，请先改名")
                temporary.rename(destination)
            return {"ok": True, "name": name, "message": "素材已导入；音色格式会在实际运行前校验"}
        finally:
            await file.close()
            temporary.unlink(missing_ok=True)

    @app.get("/audio/{job_id}/{part}")
    def audio(job_id: str, part: str):
        if not re.fullmatch(r"[a-f0-9]{32}", job_id) or part not in {"cover.mp3", "clip.mp3"}:
            raise HTTPException(404)
        job = service.jobs.get(job_id)
        if not job or job["status"] != "completed" or job.get("type") == "import":
            raise HTTPException(404)
        file = inside(root / "outputs", f"{job_id}/{part}")
        return FileResponse(file, media_type="audio/mpeg", filename=part)

    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--port", type=int, default=23339)
    arguments = parser.parse_args()
    if not 1024 <= arguments.port <= 65535:
        raise SystemExit("服务端口无效")
    import uvicorn
    uvicorn.run(create_app(Path(arguments.root).resolve(), arguments.port), host="127.0.0.1",
                port=arguments.port, log_level="warning", access_log=False)
