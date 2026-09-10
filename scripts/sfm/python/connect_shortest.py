"""Add wider temporal matches while preserving the first local reconstruction."""
from pathlib import Path
import json
import shutil
import pycolmap as pc

root = Path('/opt/gs/work/shortest-pilot/sfm384')
db = root / 'database-wide.db'
if not db.exists():
    shutil.copy2(root / 'database.db', db)
pc.match_sequential(db,
    pairing_options=pc.SequentialPairingOptions(overlap=32, quadratic_overlap=True),
    matching_options=pc.FeatureMatchingOptions(use_gpu=False, num_threads=8,
        rig_verification=True, skip_image_pairs_in_same_frame=True))
output = root / 'sparse-wide'
output.mkdir(exist_ok=True)
recs = pc.incremental_mapping(db, root / 'images', output,
    options=pc.IncrementalPipelineOptions(num_threads=8, random_seed=0,
        ba_refine_sensor_from_rig=False, ba_refine_focal_length=False,
        ba_refine_principal_point=False, ba_refine_extra_params=False))
if not recs:
    raise RuntimeError('No wider model reconstructed')
idx = max(recs, key=lambda i: recs[i].num_reg_images())
best = recs[idx]
best.export_PLY(root / 'sparse-wide.ply')
(root / 'result-wide.json').write_text(json.dumps({'best_model': idx,
    'registered_images': best.num_reg_images(), 'points3D': best.num_points3D()}, indent=2))
print('WIDE_RESULT', idx, best.summary(), flush=True)
