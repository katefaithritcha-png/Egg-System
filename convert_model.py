import tensorflow as tf
from tensorflow.keras.models import load_model
import cv2
import numpy as np

np.set_printoptions(suppress=True)

print("Loading model and labels...")
# Load model normally
model = load_model("keras_Model.h5", compile=False)
class_names = open("labels.txt", "r").readlines()

image_path = "test_egg.jpg" 
image = cv2.imread(image_path)

if image is not None:
    img = cv2.resize(image, (224, 224), interpolation=cv2.INTER_AREA)
    image_array = np.asarray(img, dtype=np.float32).reshape(1, 224, 224, 3)
    normalized_image_array = (image_array / 127.5) - 1

    try:
        # Try direct prediction first
        prediction = model.predict(normalized_image_array)
    except Exception:
        # If it fails due to expected dictionary keys, wrap input into the required dict format
        input_name = list(model.input_names)[0] if hasattr(model, 'input_names') else 'dense_Dense1_input'
        prediction = model.predict({input_name: normalized_image_array})

    index = np.argmax(prediction[0])
    class_name = class_names[index].strip()
    confidence_score = float(prediction[0][index]) * 100

    print("\n================ TEST RESULTS ================")
    print(f"Predicted Class : {class_name}")
    print(f"Confidence Score: {confidence_score:.2f}%")
    print("==============================================")
else:
    print(f"Error: Could not load image from '{image_path}'.")