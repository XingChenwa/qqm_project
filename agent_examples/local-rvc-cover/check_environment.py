"""Real CPU smoke test. A synthetic input tests separation, features and mixing;
voice conversion deliberately remains pending until the user imports a voice.
"""
import argparse
import json
import os
from pathlib import Path
import time

from pipeline import BASE_MODELS, file_sha256, run_audio, separate, ffmpeg


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    args = parser.parse_args()
    root = Path(args.root).resolve()
    os.environ["TORCH_HOME"] = str(root / "cache" / "torch")
    os.environ["NUMBA_CACHE_DIR"] = str(root / "cache" / "numba")
    os.environ["OMP_NUM_THREADS"] = "2"
    os.environ["MKL_NUM_THREADS"] = "2"
    import numpy as np
    import soundfile as sf
    import torch
    import rvc_python
    torch.set_num_threads(2)
    work = root / "self-test"
    work.mkdir(exist_ok=True)
    base = Path(rvc_python.__file__).parent / "base_model"
    for name, (size, digest) in BASE_MODELS.items():
        file = base / name
        assert file.stat().st_size == size and file_sha256(file) == digest, name
    report = {"device": "cpu", "torch": torch.__version__, "cuda": torch.cuda.is_available(),
              "baseChecksums": "passed", "voiceConversion": "pending_user_voice_model"}
    started = time.monotonic()
    time_axis = np.arange(44100 * 3, dtype=np.float32) / 44100
    wave = .12 * np.sin(2 * np.pi * 220 * time_axis) + .08 * np.sin(2 * np.pi * 440 * time_axis)
    source = work / "synthetic-input.wav"
    sf.write(source, np.stack([wave, wave * .9], axis=1), 44100, subtype="FLOAT")
    vocals, backing = separate(root, source, work)
    vocal_data, rate = sf.read(vocals)
    backing_data, backing_rate = sf.read(backing)
    assert rate == backing_rate == 44100
    assert vocal_data.shape == backing_data.shape
    assert np.isfinite(vocal_data).all() and np.isfinite(backing_data).all()
    assert vocals.stat().st_size > 100 and backing.stat().st_size > 100
    report["demucsSeparation"] = "passed"
    mix = work / "recombined.wav"
    run_audio([ffmpeg(root), "-v", "error", "-nostdin", "-y", "-protocol_whitelist", "file,pipe",
               "-i", str(vocals), "-protocol_whitelist", "file,pipe", "-i", str(backing),
               "-filter_complex", "amix=inputs=2:normalize=0", "-c:a", "pcm_f32le", str(mix)])
    reconstructed, _ = sf.read(mix)
    original, _ = sf.read(source)
    assert reconstructed.shape == original.shape
    # Neural source estimates are not guaranteed to sum exactly to the input.
    # Verify the mixer against its actual stems, and report the input residual
    # separately rather than calling separation loss a mixing error.
    error = float(np.max(np.abs(reconstructed - (vocal_data + backing_data))))
    assert error < 1e-4, error
    report.update(ffmpegMix="passed", stemMixMaxError=error,
                  sourceResidualMax=float(np.max(np.abs(reconstructed-original))))
    original_load = torch.load

    def trusted_load(file, *args, **kwargs):
        name = file if isinstance(file, (str, Path)) else getattr(file, "name", "")
        if name and Path(name).resolve() in {(base / key).resolve() for key in BASE_MODELS}:
            kwargs["weights_only"] = False
        return original_load(file, *args, **kwargs)

    torch.load = trusted_load
    try:
        from fairseq import checkpoint_utils
        models, _, _ = checkpoint_utils.load_model_ensemble_and_task([str(base / "hubert_base.pt")], suffix="")
        hubert = models[0].float().to("cpu").eval()
        audio16 = torch.sin(torch.arange(32000, dtype=torch.float32) * (2 * np.pi * 220 / 16000)) * .1
        with torch.inference_mode():
            features = hubert.extract_features(source=audio16.unsqueeze(0),
                padding_mask=torch.zeros((1,32000), dtype=torch.bool), output_layer=9)[0]
        assert features.shape[1] > 0 and torch.isfinite(features).all()
        report.update(hubertFeatures="passed", featureShape=list(features.shape))
        from rvc_python.lib.rmvpe import RMVPE
        pitch_model = RMVPE(str(base / "rmvpe.pt"), is_half=False, device="cpu")
        pitch = pitch_model.infer_from_audio(audio16.numpy(), thred=.03)
        assert pitch.size > 0 and np.isfinite(pitch).all()
        report.update(rmvpePitch="passed", pitchFrames=int(pitch.size))
    finally:
        torch.load = original_load
    report["seconds"] = round(time.monotonic()-started, 2)
    target = root / "logs" / "environment-check.json"
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
