import time
import urllib.request
from pathlib import Path

import cv2
import numpy as np
import tensorflow as tf

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
MODEL_PATH = Path(r"C:\Users\ADMIN\Downloads\converted_savedmodel\model.savedmodel")
LABELS_PATH = Path(r"C:\Users\ADMIN\Downloads\converted_savedmodel\labels.txt")
STREAM_URL = "http://192.168.11.229:81/stream"


def load_labels(labels_path: Path):
    if not labels_path.exists():
        raise FileNotFoundError(f"Labels file not found: {labels_path}")
    with labels_path.open("r", encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]


def load_model_file(model_path: Path):
    if not model_path.exists():
        raise FileNotFoundError(f"Model directory not found: {model_path}")
    loaded = tf.saved_model.load(str(model_path))
    signatures = getattr(loaded, 'signatures', None)
    if signatures is None or 'serving_default' not in signatures:
        raise RuntimeError(f"SavedModel does not expose a serving_default signature: {model_path}")
    signature = signatures['serving_default']
    input_signature = signature.structured_input_signature[1]
    if not input_signature:
        raise RuntimeError("SavedModel serving_default signature has no inputs.")
    input_name, input_spec = next(iter(input_signature.items()))
    return signature, input_name, input_spec


def preprocess_frame(frame, target_size):
    image = cv2.resize(frame, (target_size[1], target_size[0]))
    image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
    image = image.astype(np.float32) / 255.0
    return np.expand_dims(image, axis=0)


def main():
    print("Loading model and labels...")
    signature, input_name, input_spec = load_model_file(MODEL_PATH)
    labels = load_labels(LABELS_PATH)

    input_shape = input_spec.shape
    if input_shape[0] is None:
        input_shape = input_shape[1:]
    if len(input_shape) != 3:
        raise ValueError(f"Unsupported model input shape: {input_shape}")

    print(f"Model loaded from: {MODEL_PATH}")
    print(f"Labels loaded from: {LABELS_PATH}")
    print(f"Using signature input: {input_name} {input_spec}")
    print("Starting ESP32-CAM capture predictions...\n")

    headless_mode = False
    last_warning_time = 0.0

    stream = None
    byte_data = b""

    while True:
        try:
            if stream is None:
                stream = urllib.request.urlopen(STREAM_URL, timeout=5)
                print(f"Connected to stream: {STREAM_URL}")

            byte_data += stream.read(1024)
            start = byte_data.find(b'\xff\xd8')
            end = byte_data.find(b'\xff\xd9')
            if start == -1 or end == -1:
                continue

            jpg = byte_data[start:end + 2]
            byte_data = byte_data[end + 2:]
            frame = cv2.imdecode(np.frombuffer(jpg, dtype=np.uint8), cv2.IMREAD_COLOR)
            if frame is None:
                raise RuntimeError("Failed to decode JPEG frame from ESP32-CAM stream")

        except Exception as exc:
            now = time.time()
            if now - last_warning_time >= 1.0:
                print(f"Connection error: {exc}")
                last_warning_time = now
            time.sleep(2.0)
            stream = None
            byte_data = b""
            continue

        input_data = preprocess_frame(frame, input_shape)
        predictions = signature(**{input_name: tf.constant(input_data)})
        output_tensor = next(iter(predictions.values()))
        predictions = output_tensor.numpy()
        if predictions.ndim == 2 and predictions.shape[0] == 1:
            predictions = predictions[0]

        best_idx = int(np.argmax(predictions))
        best_confidence = float(predictions[best_idx]) * 100.0
        best_label = labels[best_idx] if best_idx < len(labels) else f"Class_{best_idx}"

        display_text = f"{best_label} ({best_confidence:.1f}%)"
        cv2.putText(frame, display_text, (20, 40), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2, cv2.LINE_AA)

        print("Prediction:")
        print(f"  Label     : {best_label}")
        print(f"  Confidence: {best_confidence:.2f}%")
        print(f"  Raw scores: {[round(float(x), 4) for x in predictions]}\n")

        if not headless_mode:
            try:
                cv2.imshow("ESP32-CAM Egg Detection", frame)
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break
            except cv2.error:
                headless_mode = True
                print("cv2.imshow failed, switching to terminal-only output.")
        else:
            time.sleep(0.5)

    try:
        cv2.destroyAllWindows()
    except cv2.error:
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Error: {exc}")

