"""CPU cover worker. Only a validated local job file is accepted, never a shell command."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urljoin, urlsplit, unquote

BASE_MODELS = {
    "hubert_base.pt": (189507909, "f54b40fd2802423a5643779c4861af1e9ee9c1564dc9d32f54f20b5ffba7db96"),
    "rmvpe.pt": (181184272, "6d62215f4306e3ca278246188607209f09af3dc77ed4232efdd069798c4ec193"),
}


def inside(root: Path, value: str | Path) -> Path:
    path = (root / value).resolve()
    if path != root.resolve() and root.resolve() not in path.parents:
        raise ValueError("文件超出翻唱工作目录")
    return path


def file_sha256(file: Path) -> str:
    digest = hashlib.sha256()
    with file.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def event(stage: str, **extra):
    print(json.dumps({"event": "stage", "stage": stage, **extra}, ensure_ascii=False), flush=True)


def run_audio(command: list[str]):
    result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if result.returncode:
        raise RuntimeError("音频处理失败：" + result.stderr.decode("utf-8", "replace")[-1000:])


def ffmpeg(root: Path) -> str:
    config = json.loads((root / "config.json").read_text(encoding="utf-8-sig"))
    value = str(config["ffmpeg"])
    if not Path(value).is_file():
        raise ValueError("请在本地服务 config.json 配置有效的 ffmpeg")
    return value


def separate(root: Path, source: Path, work: Path) -> tuple[Path, Path]:
    from demucs.separate import main
    event("separating", message="正在分离人声和伴奏（CPU）")
    main(["--name", "htdemucs", "--device", "cpu", "--shifts", "0",
          "--two-stems", "vocals", "--jobs", "1", "--float32",
          "--out", str(work / "separated"), str(source)])
    folder = work / "separated" / "htdemucs" / source.stem
    vocals, backing = folder / "vocals.wav", folder / "no_vocals.wav"
    if not vocals.is_file() or not backing.is_file():
        raise RuntimeError("分离服务未生成有效的人声 / 伴奏文件")
    return vocals, backing


def conversion(root: Path, voice: Path, source: Path, output: Path, pitch: int):
    import torch
    # Only the two hash-verified, upstream base checkpoints may use fairseq's
    # historical pickle loader. User voice checkpoints use weights_only=True.
    trusted = set()
    import rvc_python
    lib_dir = Path(rvc_python.__file__).parent
    for name, (size, expected) in BASE_MODELS.items():
        file = lib_dir / "base_model" / name
        if not file.is_file() or file.stat().st_size != size:
            raise ValueError(f"缺少基础模型 {name}，请运行安装脚本")
        if file_sha256(file) != expected:
            raise ValueError(f"基础模型 {name} 校验失败")
        trusted.add(file.resolve())
    original_load = torch.load

    def checked_load(file, *args, **kwargs):
        candidate = Path(file).resolve() if isinstance(file, (str, Path)) else (
            Path(file.name).resolve() if isinstance(getattr(file, "name", None), str) else None)
        if candidate in trusted:
            kwargs["weights_only"] = False
        return original_load(file, *args, **kwargs)

    # Convert a user checkpoint to tensors + primitive configuration first.
    checkpoint = original_load(voice, map_location="cpu", weights_only=True)
    if not isinstance(checkpoint, dict) or not isinstance(checkpoint.get("weight"), dict):
        raise ValueError("音色文件不是 RVC 推理模型；需要包含 weight / config 的 .pth 文件")
    if not isinstance(checkpoint.get("config"), (list, tuple)) or len(checkpoint["config"]) < 10:
        raise ValueError("RVC 音色模型缺少有效的 config")
    if not all(isinstance(key, str) and torch.is_tensor(value) for key, value in checkpoint["weight"].items()):
        raise ValueError("音色模型包含不支持的权重结构")
    config = list(checkpoint["config"])
    if not all(isinstance(value, (str, int, float, bool, list, tuple)) for value in config):
        raise ValueError("音色模型配置包含不支持的数据")
    safe_voice = output.parent / "voice.safe.pth"
    normalized = {"weight": checkpoint["weight"], "config": config,
                  "f0": int(checkpoint.get("f0", 1)),
                  "version": str(checkpoint.get("version", "v1")),
                  "sr": checkpoint.get("sr", config[-1])}
    torch.save(normalized, safe_voice)
    del checkpoint
    event("converting", message="正在转换为所选音色（CPU）")
    torch.load = checked_load
    try:
        from rvc_python import infer
        # CPU conversion never uses the optional 362MB ONNX GPU model; prevent
        # the upstream constructor from silently downloading unused assets.
        infer.download_rvc_models = lambda _lib: None
        rvc = infer.RVCInference(models_dir=str(root / "models"), device="cpu")
        rvc.load_model(str(safe_voice), version=normalized["version"])
        rvc.set_params(f0up_key=pitch, f0method="rmvpe", index_rate=0.0,
                       filter_radius=3, protect=0.33, rms_mix_rate=1.0)
        rvc.infer_file(str(source), str(output))
    finally:
        torch.load = original_load
    if not output.is_file() or output.stat().st_size < 100:
        raise RuntimeError("音色转换未生成可用音频")


def cover(root: Path, job: dict):
    import torch
    torch.set_num_threads(min(2, os.cpu_count() or 1))
    work = inside(root / "jobs", job["id"])
    work.mkdir(parents=True, exist_ok=True)
    song = inside(root / "songs", job["song_file"])
    voice = inside(root / "models", job["model_file"])
    output = inside(root / "outputs", job["id"])
    output.mkdir(parents=True, exist_ok=True)
    engine = ffmpeg(root)
    normalized = work / "input.wav"
    event("normalizing", message="正在读取歌曲")
    run_audio([engine, "-v", "error", "-nostdin", "-y", "-protocol_whitelist", "file,pipe",
               "-i", str(song), "-vn", "-ar", "44100", "-ac", "2", str(normalized)])
    vocals, backing = separate(root, normalized, work)
    converted = work / "converted.wav"
    conversion(root, voice, vocals, converted, int(job.get("pitch", 0)))
    event("mixing", message="正在混合伴奏和新音色")
    full = output / "cover.mp3"
    run_audio([engine, "-v", "error", "-nostdin", "-y", "-protocol_whitelist", "file,pipe",
               "-i", str(backing), "-protocol_whitelist", "file,pipe", "-i", str(converted),
               "-filter_complex", "[0:a]volume=0.8[b];[1:a]volume=0.95[v];[b][v]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95:latency=1",
               "-c:a", "libmp3lame", "-b:a", "192k", str(full)])
    clip = output / "clip.mp3"
    run_audio([engine, "-v", "error", "-nostdin", "-y", "-protocol_whitelist", "file,pipe",
               "-ss", str(job.get("clip_start", 0)), "-i", str(full),
               "-t", str(job.get("clip_seconds", 30)), "-ac", "1", "-ar", "24000",
               "-c:a", "libmp3lame", "-b:a", "96k", str(clip)])
    if not clip.is_file() or not 100 < clip.stat().st_size <= 5 * 1024 * 1024:
        raise RuntimeError("试听语音为空或超过 5 MB，未标记为完成")
    event("completed", message="翻唱文件已生成", full=full.name, clip=clip.name)


def music_download_url(value) -> str:
    """Only the documented same-origin /qmmer/file route may be downloaded."""
    found = []
    def visit(item, depth=0):
        if depth > 6:
            return
        if isinstance(item, str) and len(item) <= 8192:
            try:
                candidate = urljoin("https://api.avbvcv.xyz/", item)
                url = urlsplit(candidate)
                port = url.port
            except ValueError:
                return
            if (url.scheme == "https" and url.hostname == "api.avbvcv.xyz" and
                    port in (None,443) and not url.username and not url.password and
                    not url.fragment and url.path.startswith("/qmmer/file/") and
                    not {".",".."}.intersection(unquote(url.path).replace("\\","/").split("/"))):
                found.append(candidate)
        elif isinstance(item, dict):
            for child in list(item.values())[:100]:
                visit(child, depth+1)
        elif isinstance(item, list):
            for child in item[:100]:
                visit(child, depth+1)
    visit(value)
    if not found:
        raise ValueError("QQ音乐接口没有返回文档约定的有效下载链接，请检查歌曲可用性或接口文档")
    return found[0]


def import_qq_music(root: Path, job: dict):
    import requests
    event("downloading", message="正在请求 QQ 音乐音频")
    session = requests.Session()
    session.trust_env = False
    with session.post("https://api.avbvcv.xyz/", json={
            "action":"qm_song_download", "mid":job["mid"]}, timeout=(10,120),
            allow_redirects=False, stream=True) as response:
        if response.status_code != 200:
            raise ValueError(f"QQ音乐接口 HTTP {response.status_code}，没有下载或生成翻唱")
        content = bytearray()
        for chunk in response.iter_content(16384):
            content.extend(chunk)
            if len(content) > 1024*1024:
                raise ValueError("QQ音乐接口的元数据过大")
        result = json.loads(content)
    if not isinstance(result, dict) or result.get("code") != 0:
        raise ValueError("QQ音乐接口未完成下载请求，请确认歌曲 MID 和接口可用性")
    url = music_download_url(result)
    work = inside(root / "jobs", job["id"])
    audio = work / "source.audio"
    total = 0
    with session.get(url, stream=True, timeout=(10,60), allow_redirects=False) as incoming:
        if incoming.status_code != 200:
            raise ValueError(f"QQ音乐限时音频链接 HTTP {incoming.status_code}")
        if int(incoming.headers.get("Content-Length",0)) > 64*1024*1024:
            raise ValueError("歌曲音频超过64 MB，请在网页导入本地音频")
        with audio.open("wb") as output:
            for chunk in incoming.iter_content(1024*1024):
                total += len(chunk)
                if total > 64*1024*1024:
                    raise ValueError("歌曲音频超过64 MB")
                output.write(chunk)
    if total < 100:
        raise ValueError("QQ音乐下载结果为空，没有可用音频")
    event("normalizing", message="正在校验和导入歌曲音频")
    target = inside(root / "songs", job["song_file"])
    if target.exists():
        raise ValueError("同一歌曲已经存在，不覆盖原文件")
    temporary = work / "imported.mp3"
    run_audio([ffmpeg(root),"-v","error","-nostdin","-y","-protocol_whitelist","file,pipe",
               "-i",str(audio),"-vn","-ar","44100","-ac","2","-c:a","libmp3lame","-b:a","192k",str(temporary)])
    if temporary.stat().st_size < 100:
        raise ValueError("接口没有返回可解码的音乐音频")
    os.link(temporary, target)
    temporary.unlink()
    event("completed", message="QQ音乐歌曲已导入，尚未执行翻唱", song_file=target.name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--job", required=True)
    args = parser.parse_args()
    root = Path(args.root).resolve()
    os.environ["TORCH_HOME"] = str(root / "cache" / "torch")
    os.environ["NUMBA_CACHE_DIR"] = str(root / "cache" / "numba")
    os.environ["OMP_NUM_THREADS"] = "2"
    os.environ["MKL_NUM_THREADS"] = "2"
    os.environ["OPENBLAS_NUM_THREADS"] = "2"
    job_file = inside(root / "jobs", args.job)
    job = json.loads(job_file.read_text(encoding="utf-8"))
    try:
        if job.get("type") == "import":
            import_qq_music(root, job)
        else:
            cover(root, job)
    except Exception as error:
        event("failed", message=str(error)[-1200:])
        raise


if __name__ == "__main__":
    main()
