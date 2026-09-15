import json
import h5py
from pathlib import Path
p = Path('models/keras_model.h5')
with h5py.File(p, 'r') as f:
    raw = f.attrs[b'model_config']
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode('utf-8')
    cfg = json.loads(raw)

layers = cfg['config']['layers']
for i, layer in enumerate(layers,1):
    print('LAYER', i, layer['class_name'], layer['config'].get('name'))
    if layer['class_name'] == 'Sequential':
        inner = layer['config']
        print('  sub-layers', len(inner['layers']))
        for j, sl in enumerate(inner['layers'],1):
            print('   ', j, sl['class_name'], sl['config'].get('name'))
            if sl['class_name'] == 'Functional':
                print('      functional input_layers', sl['config'].get('input_layers'))
                print('      functional output_layers', sl['config'].get('output_layers'))
                print('      functional layers', len(sl['config'].get('layers', [])))
                print('      first-level inner layers:')
                for k in sl['config']['layers'][:10]:
                    print('        ', k['class_name'], k['config'].get('name'))
                print('      last-level inner layers:')
                for k in sl['config']['layers'][-5:]:
                    print('        ', k['class_name'], k['config'].get('name'))
