import json
import h5py
from pathlib import Path
p = Path('models/keras_model.h5')
with h5py.File(p, 'r') as f:
    raw = f.attrs[b'model_config']
    if isinstance(raw, (bytes, bytearray)):
        raw = raw.decode('utf-8')
    cfg = json.loads(raw)

seq = cfg['config']
print('top layers', len(seq['layers']))
for i, layer in enumerate(seq['layers'], 1):
    print('TOP', i, layer['class_name'], layer['config'].get('name'))
    if layer['class_name'] == 'Sequential':
        sub = layer['config']
        print('  sub-layers', len(sub['layers']))
        for j, sl in enumerate(sub['layers'], 1):
            print('   SUB', j, sl['class_name'], sl['config'].get('name'))
            if sl['class_name'] == 'Functional':
                inner = sl['config']
                print('     inner name', inner.get('name'))
                print('     input_layers', inner.get('input_layers'))
                print('     output_layers', inner.get('output_layers'))
                print('     inner layers', len(inner.get('layers', [])))
                outputs = inner.get('output_layers')
                if outputs:
                    for out in outputs:
                        print('      output', out)
                        layer_name = out[0]
                        print('      output layer class', next((x['class_name'] for x in inner['layers'] if x['config'].get('name') == layer_name), 'missing'))
                # locate first conv block for names
                for idx, il in enumerate(inner['layers'][:20],1):
                    print('       inner layer', idx, il['class_name'], il['config'].get('name'))
            if sl['class_name'] == 'Dense':
                print('     units', sl['config'].get('units'), 'activation', sl['config'].get('activation'))
