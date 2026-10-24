from pathlib import Path
import keras
from keras.models import load_model
print('keras version', keras.__version__)
print('cwd', Path.cwd())
print('model exists', Path('models/keras_model.h5').exists())
try:
    m = load_model('models/keras_model.h5', compile=False)
    print('loaded model', m)
    print('input_shape', m.input_shape)
    print('output_shape', m.output_shape)
except Exception as e:
    print('load_model failed', type(e).__name__, e)
