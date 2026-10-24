import json
import h5py
import tensorflow as tf
from tensorflow.keras.models import model_from_json
from tensorflow.keras import layers
from tensorflow.keras.utils import get_custom_objects
from pathlib import Path

class DepthwiseConv2DCompat(layers.DepthwiseConv2D):
    def __init__(self, *args, **kwargs):
        kwargs.pop('groups', None)
        super().__init__(*args, **kwargs)


def patch_config(config):
    if isinstance(config, dict):
        if 'class_name' in config and 'config' in config:
            classname = config['class_name']
            c = config['config']
            if isinstance(c, dict) and 'groups' in c and classname in ('DepthwiseConv2D', 'Conv2D'):
                c.pop('groups', None)
            if 'layers' in c and isinstance(c['layers'], list):
                for layer in c['layers']:
                    patch_config(layer)
            if 'config' in c and isinstance(c['config'], dict):
                patch_config(c)
        for v in config.values():
            patch_config(v)
    elif isinstance(config, list):
        for item in config:
            patch_config(item)

with h5py.File('models/keras_model.h5','r') as f:
    raw = f.attrs[b'model_config']
    if isinstance(raw, bytes):
        raw = raw.decode('utf-8')
    cfg = json.loads(raw)

patch_config(cfg)
js = json.dumps(cfg)
get_custom_objects()['DepthwiseConv2D'] = DepthwiseConv2DCompat

print('patch done')
try:
    model = model_from_json(js, custom_objects={'DepthwiseConv2D': DepthwiseConv2DCompat})
    print('model created', model)
    model.summary()
    model.load_weights('models/keras_model.h5')
    print('weights loaded')
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    tflite = converter.convert()
    Path('assets/models/egg_model.tflite').write_bytes(tflite)
    print('converted to assets/models/egg_model.tflite')
except Exception as e:
    print('failed', type(e).__name__, e)
