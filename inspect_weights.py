import h5py
from pathlib import Path
p = Path('models/keras_model.h5')
with h5py.File(p, 'r') as f:
    def walk(name, obj):
        print(name, 'group' if isinstance(obj, h5py.Group) else 'dataset', getattr(obj, 'shape', None))
    f.visititems(walk)
