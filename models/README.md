# Model files

The downloaded Keras model files have been copied into this project at:

- `models/keras_model.h5`
- `models/labels.txt`

## If you want to use this model from Python

Use the relative path from your script, for example:

```python
import tensorflow as tf

model = tf.keras.models.load_model('models/keras_model.h5')
model.summary()
```

## If you want to use this in Flutter

Flutter does not load `.h5` Keras models directly. To use it in the Flutter app, you should:

1. Convert the model to TensorFlow Lite (`.tflite`).
2. Add a Flutter package such as `tflite_flutter`.
3. Load the converted `.tflite` model from assets or file storage.

If you want, I can also help convert this model to TFLite and integrate it into your Flutter app.