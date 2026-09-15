import json
import h5py
from pathlib import Path
p = Path('models/keras_model.h5')
print('exists', p.exists())
with h5py.File(p, 'r') as f:
    print('keys', list(f.keys()))
    print('attrs keys', list(f.attrs.keys()))
    if b'model_config' in f.attrs:
        raw = f.attrs[b'model_config']
        print('raw type', type(raw))
        print('raw len', len(raw) if hasattr(raw, '__len__') else 'na')
        s = raw.decode('utf-8') if isinstance(raw, (bytes, bytearray)) else raw
        print('first 300', s[:300])
        try:
            cfg = json.loads(s)
            print('json keys', list(cfg.keys()))
            print('class_name', cfg.get('class_name'))
            print('layers count', len(cfg.get('config', {}).get('layers', [])))
            print('input_layers', cfg.get('config', {}).get('input_layers'))
            print('output_layers', cfg.get('config', {}).get('output_layers'))
        except Exception as e:
            print('json load failed', e)
print('labels', Path('models/labels.txt').read_text())
