"""Open the exported reference surface in a saved Blender scene."""
from pathlib import Path
import json
import sys
import bpy
from mathutils import Matrix, Vector

result = Path(sys.argv[sys.argv.index('--') + 1])
config = json.loads((result / 'viewer-config.json').read_text())
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.ply_import(filepath=str(result / 'terrain-reference.ply'))
surface = bpy.context.object
surface.name = 'PGSR_局部地形参考_相对尺度'
surface['说明'] = '低分辨率视频局部重建；相对尺度，孔洞和漂浮面需人工整理。'
material = bpy.data.materials.new('重建顶点颜色')
material.use_nodes = True
nodes = material.node_tree.nodes
bsdf = nodes.get('Principled BSDF')
bsdf.inputs['Roughness'].default_value = 1
if surface.data.color_attributes:
    color = nodes.new('ShaderNodeVertexColor')
    color.layer_name = surface.data.color_attributes[0].name
    material.node_tree.links.new(color.outputs['Color'], bsdf.inputs['Base Color'])
surface.data.materials.append(material)

# Use the same physical camera as the local viewer, retaining native model scale.
position = Vector(config['position'])
forward = (Vector(config['lookAt']) - position).normalized()
up = Vector(config['up']).normalized()
right = forward.cross(up).normalized()
up = right.cross(forward).normalized()
rotation = Matrix((right, up, -forward)).transposed().to_4x4()
rotation.translation = position
bpy.ops.object.camera_add()
camera = bpy.context.object
camera.name = '拍摄参考视角'
camera.matrix_world = rotation
camera.data.lens = 18
camera.data.clip_end = 10000
bpy.context.scene.camera = camera
scene = bpy.context.scene
scene.render.engine = 'BLENDER_WORKBENCH'
scene.display.shading.light = 'STUDIO'
scene.display.shading.color_type = 'VERTEX'
scene.display.shading.show_shadows = False
scene.display.shading.show_cavity = True
scene.render.resolution_x = 1280
scene.render.resolution_y = 960
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.filepath = str(result / 'mesh-preview.png')
bpy.ops.object.select_all(action='DESELECT')
surface.select_set(True)
bpy.context.view_layer.objects.active = surface
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type == 'VIEW_3D':
            area.spaces.active.region_3d.view_perspective = 'CAMERA'
            area.spaces.active.clip_end = 10000
            area.spaces.active.shading.color_type = 'VERTEX'
bpy.ops.wm.save_as_mainfile(filepath=str(result / 'terrain-reference.blend'))
bpy.ops.render.render(write_still=True)
print('BLENDER_READY', len(surface.data.vertices), len(surface.data.polygons))
