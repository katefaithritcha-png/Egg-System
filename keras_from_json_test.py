import json
import keras
from keras.models import model_from_json
from keras.utils import get_custom_objects
from keras.layers import DepthwiseConv2D
from pathlib import Path
import h5py

class DepthwiseConv2DCompat(DepthwiseConv2D):
    def __init__(self, *args, **kwargs):
        kwargs.pop('groups', None)
        super().__init__(*args, **kwargs)

get_custom_objects()['DepthwiseConv2D'] = DepthwiseConv2DCompat

with h5py.File('models/keras_model.h5', 'r') as f:
    raw = f.attrs[b'model_config']
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode('utf-8')
    cfg = json.loads(raw)
    js = json.dumps(cfg)

print('json len', len(js))
try:
    model = model_from_json(js, custom_objects={'DepthwiseConv2D': DepthwiseConv2DCompat})
    print('model created', model)
    print('model summary start')
    model.summary()
    print('load weights...')
    model.load_weights('models/keras_model.h5')
    print('weights loaded')
except Exception as e:
    print('failed', type(e).__name__, e)
