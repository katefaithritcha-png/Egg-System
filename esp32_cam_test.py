import cv2
import numpy as np
import tensorflow as tf
import os
import sys
import urllib.request

# ----------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------
ESP32_STREAM_URL = "http://192.168.11.229:81/stream"
MODEL_PATH = r"C:\Egg System\Egg System\your_actual_model_name.h5"
CLASS_LABELS = [
    "Class_0_Name",
    "Class_1_Name",
    "Class_2_Name"
]
# ----------------------------------------------------


def load_model(model_path):
    if not os.path.isfile(model_path):
        raise FileNotFoundError(f"Model file not found: {model_path}")
    model = tf.keras.models.load_model(model_path)
    return model


def get_input_dimensions(model):
    input_shape = model.input_shape
    if isinstance(input_shape, list):
        input_shape = input_shape[0]
    if input_shape[0] is None:
        input_shape = input_shape[1:]

    if len(input_shape) != 3:
        raise ValueError(f"Unsupported input shape for live camera: {input_shape}. Expected (height, width, channels).")

    return input_shape


def main():
    try:
        print("Loading model...")
        model = load_model(MODEL_PATH)
        input_shape = get_input_dimensions(model)
        target_h, target_w, target_c = input_shape
        print(f"Model loaded! Target input resolution: {target_w}x{target_h}x{target_c}")

        print(f"Connecting to ESP32-CAM at {ESP32_STREAM_URL}...")
        stream = urllib.request.urlopen(ESP32_STREAM_URL)
        print("Connected successfully! Starting Real-time Accuracy Test...")
        print("Press SPACE or 'c' to trigger a test prediction | Press 'q' to exit")

        byte_data = b""
        while True:
            byte_data += stream.read(1024)
            a = byte_data.find(b'\xff\xd8') # JPEG start
            b = byte_data.find(b'\xff\xd9') # JPEG end

            if a != -1 and b != -1:
                jpg = byte_data[a:b+2]
                byte_data = byte_data[b+2:]
                
                frame = cv2.imdecode(np.frombuffer(jpg, dtype=np.uint8), cv2.IMREAD_COLOR)
                if frame is None:
                    continue

                display_frame = frame.copy()
                cv2.putText(display_frame,
                            "Press SPACE or 'c' to Test | 'q' to Quit",
                            (10, 30),
                            cv2.FONT_HERSHEY_SIMPLEX,
                            0.6,
                            (255, 255, 255),
                            2,
                            cv2.LINE_AA)
                cv2.imshow("ESP32-CAM Live Accuracy Test", display_frame)

                key = cv2.waitKey(1) & 0xFF
                if key == ord(' ') or key == ord('c'):
                    resized_frame = cv2.resize(frame, (target_w, target_h))
                    rgb_frame = cv2.cvtColor(resized_frame, cv2.COLOR_BGR2RGB)
                    normalized_frame = rgb_frame.astype(np.float32) / 255.0
                    input_tensor = np.expand_dims(normalized_frame, axis=0)

                    predictions = model.predict(input_tensor, verbose=0)
                    if predictions.ndim == 2 and predictions.shape[0] == 1:
                        predictions = predictions[0]

                    predicted_class_idx = int(np.argmax(predictions))
                    confidence = float(predictions[predicted_class_idx]) * 100.0
                    label_name = CLASS_LABELS[predicted_class_idx] if predicted_class_idx < len(CLASS_LABELS) else f"Class {predicted_class_idx}"

                    print("\n================ DETECTED RESULT ================")
                    print(f"Predicted Object : {label_name}")
                    print(f"Confidence Level : {confidence:.2f}%")
                    print("Raw Probabilities:", [round(float(p), 4) for p in predictions])
                    print("=================================================\n")

                elif key == ord('q'):
                    break

    except Exception as exc:
        print(f"Error: {exc}")
        print("Traceback:")
        import traceback
        traceback.print_exc()
        sys.exit(1)
    finally:
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()