import json
import h5py
from pathlib import Path
p = Path('models/keras_model.h5')
with h5py.File(p, 'r') as f:
    raw = f.attrs['model_config']
    if isinstance(raw, bytes):
        raw = raw.decode('utf-8')
    cfg = json.loads(raw)
Path('models/model_config.json').write_text(json.dumps(cfg, indent=2))
print('wrote models/model_config.json')
