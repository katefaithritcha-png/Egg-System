import json
import h5py
import tensorflow as tf
from tensorflow.keras import layers
from tensorflow.keras.models import model_from_json
from tensorflow.keras.utils import get_custom_objects
from pathlib import Path

class DepthwiseConv2DCompat(layers.DepthwiseConv2D):
    def __init__(self, *args, **kwargs):
        kwargs.pop('groups', None)
        super().__init__(*args, **kwargs)


def patch_config(obj):
    if isinstance(obj, dict):
        if obj.get('class_name') in ('DepthwiseConv2D', 'Conv2D', 'SeparableConv2D'):
            cfg = obj.get('config')
            if isinstance(cfg, dict):
                cfg.pop('groups', None)
        for v in obj.values():
            patch_config(v)
    elif isinstance(obj, list):
        for item in obj:
            patch_config(item)

with h5py.File('models/keras_model.h5', 'r') as f:
    raw = f.attrs['model_config']
    if isinstance(raw, bytes):
        raw = raw.decode('utf-8')
    cfg = json.loads(raw)

patch_config(cfg)
json_str = json.dumps(cfg)
get_custom_objects()['DepthwiseConv2D'] = DepthwiseConv2DCompat

model = model_from_json(json_str, custom_objects={'DepthwiseConv2D': DepthwiseConv2DCompat})
print('MODEL_CREATED')
model.load_weights('models/keras_model.h5')
print('WEIGHTS_LOADED')
converter = tf.lite.TFLiteConverter.from_keras_model(model)
tflite = converter.convert()
Path('assets/models/egg_model.tflite').write_bytes(tflite)
print('TFLITE_WRITTEN')
