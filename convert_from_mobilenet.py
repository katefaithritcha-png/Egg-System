import tensorflow as tf
from tensorflow.keras.layers import Input, Dense
from tensorflow.keras.models import Model
from tensorflow.keras.applications import MobileNetV2
from pathlib import Path

inputs = Input(shape=(224, 224, 3), name='input_1')
base = MobileNetV2(include_top=False, weights=None, input_tensor=inputs, pooling='avg', alpha=1.0)

x = base.output
x = Dense(100, activation='relu', name='dense_Dense1')(x)
outputs = Dense(4, activation='softmax', name='dense_Dense2')(x)
model = Model(inputs, outputs, name='egg_classifier')
print('model built')
model.summary()

# load weights by name
model.load_weights('models/keras_model.h5', by_name=True)
print('weights loaded by name')

converter = tf.lite.TFLiteConverter.from_keras_model(model)
converter.optimizations = [tf.lite.Optimize.DEFAULT]
tflite_model = converter.convert()
Path('assets/models/egg_model.tflite').write_bytes(tflite_model)
print('tflite saved', Path('assets/models/egg_model.tflite').exists())
