import json
from pathlib import Path
p = Path('models/keras_model.h5')
text = p.with_suffix('.json')
import h5py
with h5py.File(p, 'r') as f:
    raw = f.attrs[b'model_config']
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode('utf-8')
    cfg = json.loads(raw)

print('class_name', cfg.get('class_name'))
seq = cfg['config']
print('name', seq.get('name'))
print('layer_count', len(seq['layers']))
for i, layer in enumerate(seq['layers'], 1):
    cls = layer['class_name']
    name = layer['config'].get('name')
    print(i, cls, name)
    if cls == 'Sequential':
        sub = layer['config']
        print('  sub-layers', len(sub['layers']))
        for j, sl in enumerate(sub['layers'],1):
            scls = sl['class_name']
            sname = sl['config'].get('name')
            print('   ', j, scls, sname)
            if scls == 'Functional':
                # print inner functional summary keys
                print('       functional config keys', list(sl['config'].keys()))
                inner = sl['config']
                print('       inner layers count', len(inner.get('layers', [])))
                print('       inner input_layers', inner.get('input_layers'))
                print('       inner output_layers', inner.get('output_layers'))
                print('       inner name', inner.get('name'))
            if scls == 'Dense':
                print('       units', sl['config'].get('units'), 'activation', sl['config'].get('activation'))
print('labels', Path('models/labels.txt').read_text())
