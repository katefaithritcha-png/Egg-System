import traceback
from pathlib import Path
import keras
from keras.models import load_model
from keras.layers import DepthwiseConv2D, Conv2D
from keras.utils import get_custom_objects

class DepthwiseConv2DCompat(DepthwiseConv2D):
    def __init__(self, *args, **kwargs):
        kwargs.pop('groups', None)
        super().__init__(*args, **kwargs)

class Conv2DCompat(Conv2D):
    def __init__(self, *args, **kwargs):
        kwargs.pop('groups', None)
        super().__init__(*args, **kwargs)

get_custom_objects()['DepthwiseConv2D'] = DepthwiseConv2DCompat
get_custom_objects()['Conv2D'] = Conv2DCompat

try:
    model = load_model('models/keras_model.h5', compile=False)
    print('SUCCESS load_model')
    print('input_shape', getattr(model, 'input_shape', None))
    print('output_shape', getattr(model, 'output_shape', None))
except Exception as e:
    print('FAIL', type(e).__name__)
    print('DETAIL', traceback.format_exception_only(type(e), e)[-1].strip())
