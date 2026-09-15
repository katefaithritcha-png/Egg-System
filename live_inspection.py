"""Live egg inspection using a TensorFlow SavedModel and webcam.

Usage: python live_inspection.py

Captures frames from the default camera (`cv2.VideoCapture(0)`), resizes to
the model input (224x224), normalizes pixels, runs inference via the
SavedModel `serving_default` signature, and overlays the predicted class and
confidence onto the live video feed. Press 'q' to quit.
"""
from pathlib import Path
import time
import sys

import cv2
import numpy as np
import tensorflow as tf


# --- Configuration -------------------------------------------------------
MODEL_PATH = Path(r"C:\Users\ADMIN\Downloads\converted_savedmodel\model.savedmodel")
LABELS_PATH = Path(r"C:\Users\ADMIN\Downloads\converted_savedmodel\labels.txt")
CAMERA_INDEX = 0


def load_labels(path: Path):
    if not path.exists():
        raise FileNotFoundError(f"Labels file not found: {path}")
    with path.open("r", encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]


def load_savedmodel_signature(model_dir: Path):
    if not model_dir.exists():
        raise FileNotFoundError(f"SavedModel directory not found: {model_dir}")
    loaded = tf.saved_model.load(str(model_dir))
    signatures = getattr(loaded, "signatures", None)
    if signatures is None or "serving_default" not in signatures:
        raise RuntimeError(f"SavedModel does not expose a serving_default signature: {model_dir}")
    signature = signatures["serving_default"]
    input_signature = signature.structured_input_signature[1]
    if not input_signature:
        raise RuntimeError("SavedModel serving_default signature has no inputs.")
    input_name, input_spec = next(iter(input_signature.items()))
    return signature, input_name, input_spec


def preprocess_frame(frame: np.ndarray, target_shape):
    # target_shape is (height, width, channels)
    h, w, _ = target_shape
    resized = cv2.resize(frame, (w, h))
    rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
    arr = rgb.astype(np.float32) / 255.0
    return np.expand_dims(arr, axis=0)


def label_color(label: str):
    s = label.lower()
    if "crack" in s or "broken" in s:
        return (0, 0, 255)  # Red (BGR)
    if "dirt" in s or "soiled" in s or "stain" in s:
        return (0, 255, 255)  # Yellow
    if "good" in s or "ok" in s or "healthy" in s:
        return (0, 255, 0)  # Green
    return (255, 255, 255)  # White default


def main():
    print("Loading model and labels...")
    signature, input_name, input_spec = load_savedmodel_signature(MODEL_PATH)
    labels = load_labels(LABELS_PATH)

    input_shape = input_spec.shape
    if input_shape[0] is None:
        input_shape = input_shape[1:]
    if len(input_shape) != 3:
        raise ValueError(f"Unsupported model input shape: {input_shape}")

    print(f"Model: {MODEL_PATH}")
    print(f"Labels: {LABELS_PATH}")
    print(f"Input tensor: {input_name} -> {input_spec}")

    cap = cv2.VideoCapture(CAMERA_INDEX)
    if not cap.isOpened():
        print("Failed to open camera.")
        sys.exit(1)

    try:
        while True:
            ret, frame = cap.read()
            if not ret or frame is None:
                time.sleep(0.01)
                continue

            input_data = preprocess_frame(frame, input_shape)

            # Run the SavedModel signature
            outputs = signature(**{input_name: tf.constant(input_data)})
            out_tensor = next(iter(outputs.values()))
            preds = out_tensor.numpy()
            if preds.ndim == 2 and preds.shape[0] == 1:
                preds = preds[0]

            best_idx = int(np.argmax(preds))
            best_conf = float(preds[best_idx]) * 100.0
            best_label = labels[best_idx] if best_idx < len(labels) else f"Class_{best_idx}"

            text = f"{best_label} ({best_conf:.1f}%)"
            color = label_color(best_label)

            # Overlay with filled rectangle for readability
            cv2.putText(frame, text, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1.0, color, 2, cv2.LINE_AA)

            cv2.imshow("Live Egg Inspection", frame)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break

    finally:
        cap.release()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
