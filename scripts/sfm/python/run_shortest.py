"""Render the existing panoramas and reconstruct their fixed virtual camera rig."""
from pathlib import Path
import json
import cv2
import numpy as np
import pycolmap as pc
from pycolmap import panorama as pano

work = Path('/opt/gs/work/shortest-pilot')
out = work / 'sfm384'
out.mkdir(exist_ok=True)
images = out / 'images'
masks = out / 'masks'
camera = pc.Camera.create_from_model_id(camera_id=0, model=pc.CameraModelId.SIMPLE_PINHOLE,
                                      focal_length=192., width=384, height=384)
camera.has_prior_focal_length = True
rotations = pano.get_virtual_rotations(4, (-35., 0., 35.))
rig = pano.create_pano_rig_config(rotations)
for sensor in rig.cameras:
    sensor.camera = camera
rays = pano.get_virtual_camera_rays(camera)
centers = np.einsum('nij,i->nj', rotations, [0, 0, 1])
nadir = cv2.imread(str(work / 'masks_src/nadir_body.png'), 0)
panos = sorted((work / 'panos').glob('*.jpg'))
if not (out / 'render.done').exists():
    for idx, rotation in enumerate(rotations):
        prefix = rig.cameras[idx].image_prefix
        (images / prefix).mkdir(parents=True, exist_ok=True)
        (masks / prefix).mkdir(parents=True, exist_ok=True)
        rays_pano = rays @ rotation
        xy = (pano.spherical_img_from_cam((1280, 640), rays_pano) - .5)
        xy = xy.reshape(384, 384, 2).transpose(1, 0, 2).astype(np.float32)
        ownership = (np.argmax(rays_pano @ centers.T, axis=-1) == idx).reshape(384, 384).T
        body = cv2.remap(nadir, xy[..., 0], xy[..., 1], cv2.INTER_NEAREST, borderMode=cv2.BORDER_WRAP)
        mask = (ownership & (body >= 128)).astype(np.uint8) * 255
        for path in panos:
            im = cv2.imread(str(path))
            rendered = cv2.remap(im, xy[..., 0], xy[..., 1], cv2.INTER_LINEAR, borderMode=cv2.BORDER_WRAP)
            cv2.imwrite(str(images / prefix / path.name), rendered, [cv2.IMWRITE_JPEG_QUALITY, 95])
            cv2.imwrite(str(masks / prefix / (path.name + '.png')), mask)
        print('RENDERED', prefix, len(panos), flush=True)
    (out / 'render.done').touch()

db = out / 'database.db'
if not (out / 'features.done').exists():
    pc.extract_features(db, images, camera_mode=pc.CameraMode.PER_FOLDER,
        reader_options=pc.ImageReaderOptions(mask_path=masks, camera_model='SIMPLE_PINHOLE',
                                              camera_params=camera.params_to_string()),
        extraction_options=pc.FeatureExtractionOptions(use_gpu=False, num_threads=8))
    with pc.Database.open(db) as database:
        pc.apply_rig_config([rig], database)
    (out / 'features.done').touch()
if not (out / 'matching.done').exists():
    pc.match_sequential(db,
        pairing_options=pc.SequentialPairingOptions(overlap=8, quadratic_overlap=False),
        matching_options=pc.FeatureMatchingOptions(use_gpu=False, num_threads=8,
            rig_verification=True, skip_image_pairs_in_same_frame=True))
    (out / 'matching.done').touch()
sparse = out / 'sparse'
sparse.mkdir(exist_ok=True)
recs = pc.incremental_mapping(db, images, sparse,
    options=pc.IncrementalPipelineOptions(num_threads=8, random_seed=0,
        ba_refine_sensor_from_rig=False, ba_refine_focal_length=False,
        ba_refine_principal_point=False, ba_refine_extra_params=False))
if not recs:
    raise RuntimeError('No reconstructed model; see mapper log')
best_id = max(recs, key=lambda i: recs[i].num_reg_images())
best = recs[best_id]
best.export_PLY(out / 'sparse.ply')
(out / 'result.json').write_text(json.dumps({'best_model': best_id,
    'registered_images': best.num_reg_images(), 'points3D': best.num_points3D()}, indent=2))
print('SFM_RESULT', best_id, best.summary(), flush=True)
