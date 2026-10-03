#!/usr/bin/env python3
"""trellis2-photo2glb - local photo/2D -> textured GLB via TRELLIS.2 on zephyr.

Runs entirely local, free, private: ComfyUI (127.0.0.1:8188) + RTX 3090.
Needs the TRELLIS.2 pack models in ComfyUI (installed 2026-10).

Usage:
  trellis2-photo2glb photo.jpg                  # 1024_cascade, removes background
  trellis2-photo2glb cutout.png --alpha         # image already has transparency
  trellis2-photo2glb photo.jpg --res 512        # faster, lower detail
  trellis2-photo2glb photo.jpg --geo-only       # untextured geometry (fast)
  trellis2-photo2glb photo.jpg --seed 7 --out-dir ~/3d-out

Output: ~/3d-out/<name>_<res>_<timestamp>.glb  (GLB with PBR material embedded)
"""
import argparse
import glob
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

HOST = "http://127.0.0.1:8188"
COMFY = os.path.expanduser("~/StabilityMatrix/Packages/ComfyUI")
INPUT_DIR = os.path.join(COMFY, "input")
OUTPUT_DIR = os.path.join(COMFY, "output")

GEO_ARGS = dict(
    remesh="on", **{
        "remesh.remesh_band": 1.0,
        "remesh.remove_inner_faces": True,
        "target_face_count": 500000,
        "floater_threshold": 0.001,
        "weld_vertices": True,
        "weld_digits": 4,
        "chart_cone_angle": 90.0,
        "chart_refine_iterations": 1,
        "chart_global_iterations": 1,
        "chart_smooth_strength": 1.0,
    })


def api_get(path):
    with urllib.request.urlopen(HOST + path, timeout=15) as r:
        return json.load(r)


def api_post(path, payload):
    req = urllib.request.Request(
        HOST + path, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def ensure_comfyui():
    try:
        api_get("/system_stats")
        return
    except Exception:
        pass
    print("[photo2glb] ComfyUI down - starting in tmux session 'comfyui'...", file=sys.stderr)
    check = subprocess.run(["tmux", "has-session", "-t", "comfyui"])
    if check.returncode != 0:
        subprocess.run(
            ["tmux", "new-session", "-d", "-s", "comfyui",
             f"cd {COMFY} && exec ./venv/bin/python main.py --listen 127.0.0.1 --port 8188"],
            check=True)
    deadline = time.time() + 240
    while time.time() < deadline:
        try:
            api_get("/system_stats")
            print("[photo2glb] ComfyUI up.", file=sys.stderr)
            return
        except Exception:
            time.sleep(3)
    sys.exit("[photo2glb] ComfyUI did not come up within 240s")


def build_workflow(img_name, res, seed, alpha_mode, geo_only, tex_size, max_tokens):
    wf = {}
    wf["1"] = {"class_type": "LoadImage", "inputs": {"image": img_name}}
    if alpha_mode:
        wf["2"] = {"class_type": "InvertMask", "inputs": {"mask": ["1", 1]}}
        cond_img, cond_mask = ["1", 0], ["2", 0]
    else:
        wf["2"] = {"class_type": "Trellis2RemoveBackground",
                   "inputs": {"image": ["1", 0], "low_vram": True}}
        cond_img, cond_mask = ["2", 0], ["2", 1]
    wf["3"] = {"class_type": "LoadTrellis2Models",
               "inputs": {"resolution": res, "precision": "auto", "attn_backend": "auto"}}
    wf["4"] = {"class_type": "Trellis2GetConditioning",
               "inputs": {"model_config": ["3", 0], "image": cond_img,
                          "mask": cond_mask, "background_color": "black"}}
    wf["5"] = {"class_type": "Trellis2ImageToShape",
               "inputs": {"model_config": ["3", 0], "conditioning": ["4", 0],
                          "seed": seed, "ss_guidance_strength": 6.5,
                          "ss_guidance_rescale": 0.05, "ss_sampling_steps": 12,
                          "shape_guidance_strength": 6.5, "shape_guidance_rescale": 0.05,
                          "shape_sampling_steps": 12, "max_tokens": max_tokens}}
    if geo_only:
        wf["6"] = {"class_type": "Trellis2ProcessMesh",
                   "inputs": {"trimesh": ["5", 0], **GEO_ARGS}}
        wf["7"] = {"class_type": "Trellis2ExportTrimesh",
                   "inputs": {"trimesh": ["6", 0], "filename_prefix": None, "file_format": "glb"}}
    else:
        wf["6"] = {"class_type": "Trellis2ShapeToTexturedMesh",
                   "inputs": {"model_config": ["3", 0], "conditioning": ["4", 0],
                              "shape_slat": ["5", 1], "subs": ["5", 2], "seed": seed,
                              "tex_guidance_strength": 3.0, "tex_guidance_rescale": 0.2,
                              "tex_sampling_steps": 12}}
        wf["7"] = {"class_type": "Trellis2ProcessMesh",
                   "inputs": {"trimesh": ["5", 0], **GEO_ARGS}}
        wf["8"] = {"class_type": "Trellis2RasterizePBR",
                   "inputs": {"trimesh": ["7", 0], "voxelgrid": ["6", 0],
                              "original_mesh": ["5", 0], "texture_size": tex_size}}
        wf["9"] = {"class_type": "Trellis2ExportTrimesh",
                   "inputs": {"trimesh": ["8", 0], "filename_prefix": None, "file_format": "glb"}}
    return wf


def set_export_prefix(wf, prefix):
    for node in wf.values():
        if node["class_type"] == "Trellis2ExportTrimesh":
            node["inputs"]["filename_prefix"] = prefix


def wait_for(prompt_id, timeout):
    start = time.time()
    while time.time() - start < timeout:
        hist = api_get(f"/history/{prompt_id}")
        entry = hist.get(prompt_id)
        if entry:
            status = entry.get("status", {})
            if status.get("status_str") == "error" or status.get("completed") is False:
                msgs = [m for m in status.get("messages", []) if m[0] == "execution_error"]
                detail = msgs[0][1] if msgs else status
                return ("error", detail)
            if status.get("completed"):
                return ("success", entry)
        time.sleep(2)
    return ("timeout", None)


def main():
    ap = argparse.ArgumentParser(description="Local photo/2D -> textured GLB (TRELLIS.2)")
    ap.add_argument("image", help="input photo or 2D asset")
    ap.add_argument("--res", default="1024_cascade",
                    choices=["512", "1024", "1024_cascade", "1536_cascade"])
    ap.add_argument("--alpha", action="store_true",
                    help="image already has transparency (skip background removal)")
    ap.add_argument("--geo-only", action="store_true", help="no texture pass")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--tex-size", type=int, default=2048)
    ap.add_argument("--max-tokens", type=int, default=None,
                    help="default: 49152 for 512, else 262144")
    ap.add_argument("--out-dir", default=os.path.expanduser("~/3d-out"))
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--keep-input", action="store_true",
                    help="do not clean up the copied input file")
    args = ap.parse_args()

    src = os.path.abspath(os.path.expanduser(args.image))
    if not os.path.isfile(src):
        sys.exit(f"[photo2glb] no such file: {src}")
    stem = os.path.splitext(os.path.basename(src))[0]
    max_tokens = args.max_tokens or (49152 if args.res == "512" else 262144)

    ensure_comfyui()
    os.makedirs(INPUT_DIR, exist_ok=True)
    os.makedirs(args.out_dir, exist_ok=True)

    with open(src, "rb") as f:
        digest = hashlib.sha1(f.read()).hexdigest()[:8]
    ext = os.path.splitext(src)[1].lower()
    img_name = f"p2g_{digest}{ext}"
    shutil.copy(src, os.path.join(INPUT_DIR, img_name))

    tag = args.res.replace("_cascade", "c")
    prefix = f"trellis2/{stem}_{tag}"
    wf = build_workflow(img_name, args.res, args.seed, args.alpha,
                        args.geo_only, args.tex_size, max_tokens)
    set_export_prefix(wf, prefix)

    print(f"[photo2glb] submitting: res={args.res} alpha_mode={args.alpha} "
          f"geo_only={args.geo_only} seed={args.seed}", file=sys.stderr)
    resp = api_post("/prompt", {"prompt": wf, "client_id": "photo2glb"})
    if "prompt_id" not in resp:
        sys.exit(f"[photo2glb] submit rejected: {json.dumps(resp)[:800]}")
    prompt_id = resp["prompt_id"]
    print(f"[photo2glb] prompt_id={prompt_id} waiting...", file=sys.stderr)

    state, detail = wait_for(prompt_id, args.timeout)
    if state != "success":
        sys.exit(f"[photo2glb] render {state}: {json.dumps(detail)[:1200] if detail else 'timeout'}")

    matches = sorted(glob.glob(os.path.join(OUTPUT_DIR, prefix + "_*.glb")),
                     key=os.path.getmtime)
    if not matches:
        sys.exit("[photo2glb] render finished but no GLB found")
    latest = matches[-1]
    ts = time.strftime("%Y%m%d_%H%M%S")
    dest = os.path.join(args.out_dir, f"{stem}_{tag}_{ts}.glb")
    shutil.copy(latest, dest)
    if not args.keep_input:
        try:
            os.remove(os.path.join(INPUT_DIR, img_name))
        except OSError:
            pass
    print(dest)


if __name__ == "__main__":
    main()
