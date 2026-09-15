import os
import sys
import traceback

import numpy as np
from PIL import Image
import tensorflow as tf

MODEL_PATH = "models/model.h5"


def load_model(model_path):
    if not os.path.isfile(model_path):
        raise FileNotFoundError(f"Model file not found: {model_path}")

    model = tf.keras.models.load_model(model_path)
    print(f"Loaded model from: {model_path}")
    input_shape = model.input_shape
    output_shape = model.output_shape
    layer_count = len(model.layers)
    print(f"Model input shape: {input_shape}")
    print(f"Model output shape: {output_shape}")
    print(f"Model layer count: {layer_count}")
    return model


def get_model_input_shape(model):
    input_shape = model.input_shape
    if isinstance(input_shape, list):
        input_shape = input_shape[0]
    if input_shape[0] is None:
        input_shape = input_shape[1:]
    return tuple(input_shape)


def build_dummy_input(input_shape):
    if any(d is None for d in input_shape):
        raise ValueError(f"Cannot build dummy input for shape with undefined dimensions: {input_shape}")
    return np.random.random_sample((1,) + input_shape).astype(np.float32)


def normalize_image_array(image_array, input_shape):
    image_array = image_array.astype(np.float32) / 255.0
    if image_array.shape != input_shape:
        if image_array.ndim == 2 and len(input_shape) == 3:
            image_array = np.expand_dims(image_array, axis=-1)
        if image_array.ndim == 3 and len(input_shape) == 3:
            if image_array.shape[-1] != input_shape[-1]:
                if input_shape[-1] == 1:
                    image_array = np.mean(image_array, axis=-1, keepdims=True)
                elif image_array.shape[-1] == 1 and input_shape[-1] == 3:
                    image_array = np.repeat(image_array, 3, axis=-1)
        if image_array.shape != input_shape:
            raise ValueError(f"Image array shape {image_array.shape} does not match required model input shape {input_shape}")
    return image_array


def test_image_prediction(model, image_path):
    if not os.path.isfile(image_path):
        raise FileNotFoundError(f"Image file not found: {image_path}")

    input_shape = get_model_input_shape(model)
    if len(input_shape) not in (2, 3):
        raise ValueError(f"Unsupported model input shape for image prediction: {input_shape}")

    width, height = input_shape[1], input_shape[0] if len(input_shape) == 3 else input_shape[1]
    if len(input_shape) == 2:
        width, height = input_shape[1], input_shape[0]

    image = Image.open(image_path).convert("RGB")
    image = image.resize((input_shape[1], input_shape[0]), Image.BILINEAR)
    image_array = np.asarray(image)

    if len(input_shape) == 2:
        image_array = np.mean(image_array, axis=-1)
    elif len(input_shape) == 3 and input_shape[-1] == 1:
        image_array = np.mean(image_array, axis=-1, keepdims=True)

    image_array = normalize_image_array(image_array, input_shape)
    image_batch = np.expand_dims(image_array, axis=0)

    predictions = model.predict(image_batch)

    class_index = np.argmax(predictions, axis=-1) if predictions.ndim > 1 else np.argmax(predictions)
    print(f"Image prediction for '{image_path}' complete.")
    print(f"Predicted class index: {class_index}")
    print(f"Prediction output array: {predictions}")
    return predictions


def main():
    try:
        model = load_model(MODEL_PATH)

        input_shape = get_model_input_shape(model)
        dummy_input = build_dummy_input(input_shape)
        print(f"Running dummy input inference with shape: {dummy_input.shape}")
        dummy_output = model.predict(dummy_input)
        print("Dummy inference output:")
        print(dummy_output)

        if len(sys.argv) > 1:
            sample_image_path = sys.argv[1]
            print(f"\nTesting sample image: {sample_image_path}")
            test_image_prediction(model, sample_image_path)
        else:
            print("\nNo sample image path supplied. Skipping image prediction test.")

        print("\nModel validation completed successfully.")
    except Exception as exc:
        print("\nModel validation failed.")
        print(f"Error: {exc}")
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
