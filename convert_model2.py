import tensorflow as tf
from tensorflow.keras import layers, models
from tensorflow.keras.utils import get_custom_objects

class DepthwiseConv2DCompat(layers.DepthwiseConv2D):
    def __init__(self, *args, **kwargs):
        kwargs.pop('groups', None)
        super().__init__(*args, **kwargs)

get_custom_objects()['DepthwiseConv2D'] = DepthwiseConv2DCompat

try:
    model = models.load_model('models/keras_model.h5', compile=False)
    print('loaded model directly')
except Exception as e:
    print('direct load failed', e)
    try:
        from tensorflow.keras.saving.hdf5_format import load_model_from_hdf5
        model = load_model_from_hdf5('models/keras_model.h5', custom_objects={'DepthwiseConv2D': DepthwiseConv2DCompat})
        print('loaded with load_model_from_hdf5')
    except Exception as e2:
        print('load_model_from_hdf5 failed', e2)
        raise

print('MODEL:', model)
print('INPUT SHAPE', getattr(model, 'input_shape', None))
print('OUTPUT SHAPE', getattr(model, 'output_shape', None))
converter = tf.lite.TFLiteConverter.from_keras_model(model)
tflite = converter.convert()
with open('assets/models/egg_model.tflite','wb') as f:
    f.write(tflite)
print('converted tflite saved')
