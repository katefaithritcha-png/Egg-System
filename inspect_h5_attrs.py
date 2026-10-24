import h5py
from pathlib import Path
p = Path('models/keras_model.h5')
with h5py.File(p, 'r') as f:
    print('keras_version', f.attrs['keras_version'])
    print('backend', f.attrs['backend'])
