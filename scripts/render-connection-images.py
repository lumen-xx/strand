# Renders Strand's connection images from free 3D models (credited in THIRD_PARTY_NOTICES.md) on transparent backgrounds.
# Models are glTF downloads from Sketchfab unpacked to work/models/<key>/scene.gltf (see ConnectionImages/sources.json).
# Usage: Blender -b --factory-startup --python scripts/render-connection-images.py -- <models dir> <out dir> [name ...] [--quick]
import bpy, bmesh, math, os, sys
import numpy as np
from mathutils import Matrix, Vector

ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
QUICK = "--quick" in ARGS
ARGS = [a for a in ARGS if a != "--quick"]
MODELS, OUT = os.path.abspath(ARGS[0]), os.path.abspath(ARGS[1])
ONLY = set(ARGS[2:])
RES = 1000 if QUICK else 2000
SAMPLES = 48 if QUICK else 384
BORDER = 0.06
V = Vector
STUDIO = next(os.path.join(root, "studio.exr") for root, _, files in os.walk(os.path.dirname(bpy.app.binary_path) + "/../Resources") if "studio.exr" in files)

# MARK: Scene

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'
    prefs.get_devices()
    for device in prefs.devices:
        device.use = True
    scene.cycles.device = 'GPU'
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = True
    scene.cycles.max_bounces = 12
    scene.render.film_transparent = True
    scene.render.resolution_x = scene.render.resolution_y = RES
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.image_settings.color_depth = '16'
    scene.view_settings.view_transform = 'AgX'
    scene.view_settings.look = 'AgX - Base Contrast'
    scene.view_settings.exposure = 1.15
    world = bpy.data.worlds.new("studio")
    scene.world = world
    nodes, links = world.node_tree.nodes, world.node_tree.links
    nodes.clear()
    env = nodes.new("ShaderNodeTexEnvironment")
    env.image = bpy.data.images.load(STUDIO)
    # A neutral studio: the bundled HDRI's colour cast would tint black products.
    grey = nodes.new("ShaderNodeHueSaturation")
    grey.inputs["Saturation"].default_value = 0.0
    background = nodes.new("ShaderNodeBackground")
    background.inputs["Strength"].default_value = 0.9
    links.new(env.outputs[0], grey.inputs["Color"])
    links.new(grey.outputs[0], background.inputs[0])
    links.new(background.outputs[0], nodes.new("ShaderNodeOutputWorld").inputs[0])

def link(ob):
    bpy.context.scene.collection.objects.link(ob)
    return ob

def import_model(key, scale=1.0):
    """Imports a glTF, applies its transforms and returns the mesh objects (empties removed)."""
    before = set(bpy.context.scene.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(MODELS, key, "scene.gltf"))
    new = [o for o in bpy.context.scene.objects if o not in before]
    meshes = [o for o in new if o.type == 'MESH']
    for ob in meshes:
        matrix = ob.matrix_world.copy()
        ob.parent = None
        ob.matrix_world = Matrix.Scale(scale, 4) @ matrix
    bpy.ops.object.select_all(action='DESELECT')
    for ob in meshes:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for ob in new:
        if ob.type != 'MESH':
            bpy.data.objects.remove(ob)
    return meshes

def bounds(objects):
    bpy.context.view_layer.update()
    points = [o.matrix_world @ V(c) for o in objects for c in o.bound_box]
    return (V((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points))),
            V((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points))))

def transform(objects, matrix):
    """Moves geometry itself, so later vertex edits and bounds see the same coordinates."""
    for ob in objects:
        if ob.type == 'MESH' and ob.matrix_world == Matrix.Identity(4):
            ob.data.transform(matrix)
            ob.data.update()
        else:
            ob.matrix_world = matrix @ ob.matrix_world

# MARK: Materials

def material(name, color, rough=0.4, metal=0.0, coat=0.0, sheen=0.0, subsurface=0.0, aniso=0.0, emit=0.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    bsdf.inputs["Coat Weight"].default_value = coat
    bsdf.inputs["Coat Roughness"].default_value = 0.15
    bsdf.inputs["Sheen Weight"].default_value = sheen
    bsdf.inputs["Subsurface Weight"].default_value = subsurface
    bsdf.inputs["Subsurface Radius"].default_value = (0.08, 0.08, 0.08)
    bsdf.inputs["Anisotropic"].default_value = aniso
    if emit:
        bsdf.inputs["Emission Color"].default_value = (*color, 1)
        bsdf.inputs["Emission Strength"].default_value = emit
    return mat

def assign(objects, mat):
    for ob in objects:
        ob.data.materials.clear()
        ob.data.materials.append(mat)

def braid(name, color, pitch=0.11, sheen=0.6):
    """Woven jacket: two diagonal strand families over/under in a 2x2 twill, driven by the tube's UVs (cm)."""
    mat = material(name, color, rough=0.62, sheen=sheen)
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = nodes["Principled BSDF"]
    uv = nodes.new("ShaderNodeUVMap")
    split = nodes.new("ShaderNodeSeparateXYZ")
    links.new(uv.outputs[0], split.inputs[0])
    def math_(op, a, b=None, value=None):
        node = nodes.new("ShaderNodeMath")
        node.operation = op
        for i, x in enumerate((a, b)):
            if x is None:
                if i == 1 and value is not None:
                    node.inputs[1].default_value = value
            elif isinstance(x, (int, float)):
                node.inputs[i].default_value = x
            else:
                links.new(x, node.inputs[i])
        return node.outputs[0]
    u, v = split.outputs[0], split.outputs[1]
    a = math_('DIVIDE', math_('ADD', u, v), pitch)
    b = math_('DIVIDE', math_('SUBTRACT', u, v), pitch)
    strand_a = math_('SINE', math_('MULTIPLY', math_('FRACT', a), math.pi))
    strand_b = math_('SINE', math_('MULTIPLY', math_('FRACT', b), math.pi))
    cell = math_('MODULO', math_('ADD', math_('FLOOR', math_('DIVIDE', a, 2)), math_('FLOOR', math_('DIVIDE', b, 2))), 2)
    mix = nodes.new("ShaderNodeMix")
    mix.data_type = 'FLOAT'
    links.new(cell, mix.inputs["Factor"])
    links.new(strand_a, mix.inputs["A"])
    links.new(strand_b, mix.inputs["B"])
    height = mix.outputs["Result"]
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.55
    bump.inputs["Distance"].default_value = 0.02
    links.new(height, bump.inputs["Height"])
    links.new(bump.outputs[0], bsdf.inputs["Normal"])
    shade = nodes.new("ShaderNodeMix")
    shade.data_type = 'RGBA'
    shade.inputs["A"].default_value = (*[c * 0.72 for c in color], 1)
    shade.inputs["B"].default_value = (*color, 1)
    links.new(height, shade.inputs["Factor"])
    links.new(shade.outputs["Result"], bsdf.inputs["Base Color"])
    return mat

# MARK: Cable geometry

def smooth_path(points, passes=40):
    pts = [p.copy() for p in points]
    for _ in range(passes):
        pts = [pts[0]] + [(pts[i - 1] + pts[i] * 2 + pts[i + 1]) / 4 for i in range(1, len(pts) - 1)] + [pts[-1]]
    return pts

def resample(points, step):
    out, carry = [points[0]], 0.0
    for a, b in zip(points, points[1:]):
        seg = (b - a).length
        t = step - carry
        while t <= seg:
            out.append(a.lerp(b, t / seg))
            t += step
        carry = seg - (t - step)
    if (out[-1] - points[-1]).length > step * 0.2:
        out.append(points[-1])
    return out

def tube(name, points, radius, mat, sides=36):
    """A smooth cable with parallel-transport frames and UVs in centimetres (u along, v around)."""
    tangents = [(points[min(i + 1, len(points) - 1)] - points[max(i - 1, 0)]).normalized() for i in range(len(points))]
    normal = tangents[0].orthogonal().normalized()
    bm = bmesh.new()
    rings, length = [], 0.0
    lengths = [0.0]
    for i in range(1, len(points)):
        lengths.append(lengths[-1] + (points[i] - points[i - 1]).length)
    for i, (p, t) in enumerate(zip(points, tangents)):
        if i:
            normal = (normal - t * normal.dot(t)).normalized()
        binormal = t.cross(normal)
        rings.append([bm.verts.new(p + (normal * math.cos(a) + binormal * math.sin(a)) * radius)
                      for a in (2 * math.pi * k / sides for k in range(sides))])
    uv_layer = bm.loops.layers.uv.new()
    circumference = 2 * math.pi * radius
    for i in range(len(rings) - 1):
        for k in range(sides):
            corners = [(i, k), (i + 1, k), (i + 1, k + 1), (i, k + 1)]
            face = bm.faces.new([rings[r][c % sides] for r, c in corners])
            face.smooth = True
            for loop, (r, c) in zip(face.loops, corners):
                loop[uv_layer].uv = (lengths[r], circumference * c / sides)
    for ring in (rings[0], rings[-1]):
        cap = bm.faces.new(ring if ring is rings[-1] else list(reversed(ring)))
        cap.smooth = True
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    me.materials.append(mat)
    return link(bpy.data.objects.new(name, me))

def coil(radius, rise, cable, end_height, turns=1.5):
    """Both plugs point up and the cable drops into a loose loop, like a boxed cable.
    Returns the centre line and where each connector meets the cable."""
    sweep = 2 * math.pi * turns
    loop = []
    count = 400
    for i in range(count + 1):
        s = i / count
        angle = math.pi + sweep * s
        r = radius * (1 + 0.06 * math.sin(2 * math.pi * 1.25 * s + 0.3) - 0.025 * math.sin(math.pi * s))
        loop.append(V((r * math.cos(angle), 0.94 * r * math.sin(angle), cable / 2 + cable * 1.02 * s)))
    first, last = loop[0], loop[-1]
    left = [V((first.x, rise * (1 - t), cable / 2 + (end_height - cable / 2) * (1 - t) ** 3)) for t in (i / 40 for i in range(40))]
    right = [V((last.x, rise * t, last.z + (end_height - last.z) * t ** 3)) for t in (i / 40 for i in range(1, 41))]
    path = resample(smooth_path(left + loop + right, 25), 0.06)
    return path, V((first.x, rise, end_height)), V((last.x, rise, end_height))

# MARK: Connectors

def usb_c_connectors(dark, long_housing=1.0, collar=False):
    """The two USB-C ends of the downloaded cable, each re-centred so its cable entry is the origin and it points +Y (cm)."""
    parts = import_model("usbc1", scale=12.0)
    shell = material("shell", (0.022, 0.022, 0.024) if dark else (0.93, 0.93, 0.92), 0.32, coat=0.25, subsurface=0 if dark else 0.12)
    relief = material("relief", (0.03, 0.03, 0.032) if dark else (0.9, 0.9, 0.89), 0.45, subsurface=0 if dark else 0.1)
    steel = material("steel", (0.92, 0.92, 0.92), 0.22, metal=1)
    ends = []
    for side in (-1, 1):
        mine = [o for o in parts if (o.location.x + sum((o.matrix_world @ V(c)).x for c in o.bound_box) / 8) * side > 0 and o.name != "Object_20"]
        ends.append(mine)
    for ob in parts:
        if ob.name == "Object_20":
            bpy.data.objects.remove(ob)
    result = []
    for mine in ends:
        lo, hi = bounds(mine)
        entry = V(((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2))
        transform(mine, Matrix.Translation(-entry))
        for ob in mine:
            name = ob.data.materials[0].name if ob.data.materials else ""
            assign([ob], steel if "metal" in name else relief if "grain" in name else shell)
            if long_housing != 1.0:
                # Thunderbolt cables have longer housings; stretch the housing and push the plug forward.
                y0, y1 = 0.84, 3.12
                for v in ob.data.vertices:
                    if v.co.y > y1:
                        v.co.y += (y1 - y0) * (long_housing - 1)
                    elif v.co.y > y0:
                        v.co.y = y0 + (v.co.y - y0) * long_housing
                    if "black" in name and "grain" not in name:
                        v.co.x *= 1.08
                        v.co.z *= 1.1
        if collar:
            lo, hi = bounds(mine)
            ring = bpy.data.meshes.new("collar")
            bm = bmesh.new()
            bmesh.ops.create_cube(bm, size=1)
            bmesh.ops.scale(bm, vec=(hi.x - lo.x + 0.03, 0.22, hi.z - lo.z + 0.03), verts=bm.verts)
            bm.to_mesh(ring)
            bm.free()
            band = link(bpy.data.objects.new("collar", ring))
            band.location = (0, hi.y - 0.84 - 0.11, 0)
            bevel = band.modifiers.new("bevel", 'BEVEL')
            bevel.width, bevel.segments = 0.12, 6
            for poly in ring.polygons:
                poly.use_smooth = True
            ring.materials.append(material("collar", (0.62, 0.63, 0.65) if dark else (0.8, 0.81, 0.82), 0.22, metal=1, aniso=0.6))
            mine.append(band)
        result.append(mine)
    return result

def magsafe_connector(dark):
    """MagSafe 3 plug, modelled from its published shape: a thin aluminium slab with a stepped magnetic face and LED."""
    objects = []
    def rounded(name, size, loc, radius, mat, segments=10):
        me = bpy.data.meshes.new(name)
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=1)
        bmesh.ops.scale(bm, vec=size, verts=bm.verts)
        bm.to_mesh(me)
        bm.free()
        ob = link(bpy.data.objects.new(name, me))
        ob.location = loc
        mod = ob.modifiers.new("bevel", 'BEVEL')
        mod.width, mod.segments, mod.limit_method = radius, segments, 'NONE'
        mod.harden_normals = True
        for poly in me.polygons:
            poly.use_smooth = True
        me.materials.append(mat)
        objects.append(ob)
        return ob
    alu = material("magsafe", (0.05, 0.05, 0.055) if dark else (0.84, 0.85, 0.86), 0.28, metal=1, aniso=0.3)
    face = material("face", (0.02, 0.02, 0.022), 0.35)
    pins = material("pins", (0.95, 0.78, 0.45), 0.2, metal=1)
    rounded("neck", (0.62, 0.7, 0.5), (0, 0.3, 0), 0.24, material("neck", (0.03, 0.03, 0.032) if dark else (0.9, 0.9, 0.89), 0.4))
    rounded("body", (1.65, 1.45, 0.52), (0, 1.2, 0), 0.25, alu)
    rounded("face", (1.5, 0.2, 0.42), (0, 1.98, 0), 0.19, face)
    for i in range(5):
        rounded("pin", (0.12, 0.06, 0.12), (-0.4 + i * 0.2, 2.08, 0), 0.05, pins, 4)
    rounded("led", (0.09, 0.09, 0.02), (0, 1.62, 0.26), 0.04, material("led", (0.25, 1.0, 0.4), 0.3, emit=12), 4)
    # MagSafe 3 is almost twice as wide as a USB-C housing.
    transform(objects, Matrix.Scale(1.5, 4))
    return objects

# MARK: Scenes

def cable_scene(kind, dark):
    jacket = braid("jacket", (0.05, 0.05, 0.055) if dark else (0.92, 0.92, 0.91), sheen=1.0 if dark else 0.5)
    radius = {"usb-c": 0.28, "thunderbolt-4": 0.31, "thunderbolt-5": 0.33, "magsafe": 0.27}[kind]
    if kind == "magsafe":
        usb, spare = usb_c_connectors(dark)
        for ob in spare:
            bpy.data.objects.remove(ob)
        ends = [usb, magsafe_connector(dark)]
    else:
        ends = usb_c_connectors(dark, long_housing=1.0 if kind == "usb-c" else 1.3, collar=kind == "thunderbolt-5")
    height = 0.36
    path, left, right = coil(8.0, 9.5, radius * 2, height)
    tube("cable", path, radius, jacket)
    for objects, at in zip(ends, (left, right)):
        transform(objects, Matrix.Translation(at - V((0, 0.12, 0))))
    return V((0, 0, 1))

def axis_frame(origin, forward, up):
    """Rotation and translation that move `origin` to 0 with `forward` along +Y and `up` along +Z."""
    forward = forward.normalized()
    up = (up - forward * up.dot(forward)).normalized()
    side = forward.cross(up)
    return Matrix((side, forward, up)).to_4x4() @ Matrix.Translation(-origin)

def centroid(objects):
    lo, hi = bounds(objects)
    return (lo + hi) / 2

def ethernet_scene(dark):
    parts = {o.name: o for o in import_model("eth3")}
    plug = [parts[n] for n in ("Rabber_up_1_Rabber_up_0", "Rabber_up_Rabber_up_0", "Contacts_Contacts_0", "Wire_mini_Wire_mini_0", "Plastic_Plastic_0")]
    for ob in list(parts.values()):
        if ob not in plug:
            bpy.data.objects.remove(ob)
    boot, contacts, body = plug[:2], plug[2], plug[4]
    axis = centroid([contacts]) - centroid(boot)
    transform(plug, axis_frame(centroid(boot), axis, V((0, 0, 1)) if abs(axis.normalized().z) < 0.9 else V((1, 0, 0))))
    # Roll about the plug's axis so its wide face looks at the camera, contacts up.
    lo, hi = bounds([body])
    if hi.z - lo.z > hi.x - lo.x:
        transform(plug, Matrix.Rotation(math.pi / 2, 4, 'Y'))
    if centroid([contacts]).z < centroid([body]).z:
        transform(plug, Matrix.Rotation(math.pi, 4, 'Y'))
    lo, hi = bounds([body])
    transform(plug, Matrix.Scale(1.17 / (hi.x - lo.x), 4))
    jacket_color = (0.07, 0.07, 0.075)
    assign(boot, material("boot", jacket_color, 0.5))
    lo, hi = bounds(plug)
    transform(plug, Matrix.Translation(-V((0, lo.y, 0))))
    second = [ob.copy() for ob in plug]
    for ob in second:
        ob.data = ob.data.copy()
        link(ob)
    path, left, right = coil(9.0, 10.0, 0.62, 0.0)
    tube("cable", path, 0.31, braid("jacket", jacket_color, sheen=1.0))
    for objects, at in zip((plug, second), (left, right)):
        transform(objects, Matrix.Translation(at - V((0, 0.25, 0))))
    return V((0, 0, 1))

def charger_scene(dark):
    parts = import_model("chg6", scale=100.0)
    shell = (0.022, 0.022, 0.024) if dark else (0.93, 0.93, 0.92)
    done = set()
    for ob in parts:
        for mat in ob.data.materials:
            if not mat or mat.name in done:
                continue
            done.add(mat.name)
            key = mat.name.lower()
            # Flat colours also drop the regulatory print in the shell texture.
            if "port_mat" in key or "connector" in key:
                recolor(mat, (0.015, 0.015, 0.016), 0.5)
            elif "metal" in key or "tips" in key:
                recolor(mat, (0.88, 0.88, 0.88), 0.22, metal=1)
            else:
                recolor(mat, shell, 0.36, coat=0.15)
    # The broad side with the pins to the left and the USB-C port face turned toward the camera.
    return V((0.5, -1.0, 0.4)).normalized()

def rounded_box(name, size, radius, mat, edge=0.0, segments=16):
    """A box whose Z edges are rounded by `radius`; `edge` adds a smaller bevel to every other sharp edge."""
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1)
    bmesh.ops.scale(bm, vec=size, verts=bm.verts)
    upright = [e for e in bm.edges if abs((e.verts[0].co - e.verts[1].co).normalized().z) > 0.9]
    bmesh.ops.bevel(bm, geom=upright, offset=radius, segments=segments, profile=0.5, affect='EDGES', clamp_overlap=True)
    bm.to_mesh(me)
    bm.free()
    ob = link(bpy.data.objects.new(name, me))
    if edge:
        mod = ob.modifiers.new("edge", 'BEVEL')
        mod.width, mod.segments, mod.limit_method, mod.angle_limit = edge, 8, 'ANGLE', math.radians(60)
        mod.harden_normals = True
    for poly in me.polygons:
        poly.use_smooth = True
    me.materials.append(mat)
    return ob

def satin_metal(name, color, rough=0.34):
    """Bead-blasted anodised aluminium: metallic with a fine random grain."""
    mat = material(name, color, rough, metal=1)
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 260
    noise.inputs["Detail"].default_value = 2
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.04
    links.new(noise.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs[0], nodes["Principled BSDF"].inputs["Normal"])
    return mat

def hub_scene(dark):
    """A slim aluminium USB-C hub modelled for Strand, seen from above: HDMI, two USB-A, USB-C and SD on its front, a short braided lead."""
    alu = satin_metal("aluminium", (0.2, 0.2, 0.215) if dark else (0.8, 0.805, 0.81))
    hole = material("hole", (0.012, 0.012, 0.013), 0.55)
    tongue = material("tongue", (0.03, 0.03, 0.033), 0.4)
    steel = material("steel", (0.86, 0.86, 0.86), 0.25, metal=1)
    length, depth, height = 12.0, 3.6, 1.3
    body = rounded_box("hub", (length, depth, height), 0.75, alu, edge=0.2)
    front = -depth / 2
    x = -4.82
    for kind, w, h in (("hdmi", 1.5, 0.6), ("usb-a", 1.32, 0.54), ("usb-a", 1.32, 0.54), ("usb-c", 0.9, 0.34), ("sd", 2.4, 0.22)):
        cx = x + w / 2
        x += w + 0.55
        r = {"usb-c": 0.16, "sd": 0.06, "hdmi": 0.08}.get(kind, 0.04)
        cut = rounded_box("cut", (w, h, 2.0), r, hole, segments=8)
        # Flat cutters keep the cut walls from bending the shading of the front face.
        for poly in cut.data.polygons:
            poly.use_smooth = False
        transform([cut], Matrix.Translation((cx, front, 0)) @ Matrix.Rotation(math.pi / 2, 4, 'X'))
        boolean = body.modifiers.new("port", 'BOOLEAN')
        boolean.operation, boolean.object, boolean.solver = 'DIFFERENCE', cut, 'EXACT'
        cut.hide_render = True
        back = rounded_box("back", (w, h, 0.1), r, hole, segments=8)
        transform([back], Matrix.Translation((cx, front + 0.75, 0)) @ Matrix.Rotation(math.pi / 2, 4, 'X'))
        if kind in ("usb-a", "usb-c", "hdmi"):
            # A steel shell lines the opening; the tongue sits inside it.
            liner = rounded_box("liner", (w - 0.02, h - 0.02, 0.7), max(r - 0.01, 0.01), steel, segments=8)
            inner = rounded_box("inner", (w - 0.08, h - 0.08, 1.0), max(r - 0.04, 0.01), steel, segments=8)
            transform([liner], Matrix.Translation((cx, front + 0.38, 0)) @ Matrix.Rotation(math.pi / 2, 4, 'X'))
            transform([inner], Matrix.Translation((cx, front + 0.3, 0)) @ Matrix.Rotation(math.pi / 2, 4, 'X'))
            hollow = liner.modifiers.new("hollow", 'BOOLEAN')
            hollow.operation, hollow.object, hollow.solver = 'DIFFERENCE', inner, 'EXACT'
            inner.hide_render = True
            tw, th, tz = {"usb-a": (w - 0.24, 0.17, 0.1), "usb-c": (w - 0.3, 0.06, 0.0), "hdmi": (w - 0.3, 0.12, 0.08)}[kind]
            plate = rounded_box("tongue", (tw, 0.6, th), 0.02, tongue, segments=4)
            plate.location = (cx, front + 0.42, tz)
    rounded_box("led", (0.16, 0.16, 0.02), 0.08, material("led", (0.9, 0.95, 1.0), 0.3, emit=6), segments=8).location = (-length / 2 + 1.1, 0.9, height / 2 + 0.005)
    # A short braided lead leaves the left end and turns up, so its plug points the same way as the cables' plugs.
    table = -height / 2
    usb, spare = usb_c_connectors(dark)
    for ob in spare:
        bpy.data.objects.remove(ob)
    lo, hi = bounds(usb)
    lift = table + (hi.z - lo.z) / 2
    radius = 0.21
    relief = rounded_box("relief", (0.6, 0.6, 1.0), 0.29, material("relief", (0.03, 0.03, 0.032) if dark else (0.88, 0.88, 0.87), 0.45), segments=12)
    transform([relief], Matrix.Translation((-length / 2 - 0.3, 0, 0)) @ Matrix.Rotation(math.pi / 2, 4, 'Y'))
    centre, bend = V((-length / 2 - 0.6, 2.8, 0)), 2.8
    dense = [V((-length / 2 - 0.6 * t / 10, 0, 0)) for t in range(10)]
    dense += [centre + V((bend * math.cos(a_), bend * math.sin(a_), 0)) for a_ in (-math.pi / 2 - math.pi / 2 * t / 60 for t in range(61))]
    dense += [V((centre.x - bend, centre.y + 1.4 * t / 10, 0)) for t in range(1, 11)]
    for i, p_ in enumerate(dense):
        p_.z = lift * min(1.0, i / 25)
    path = resample(smooth_path(dense, 20), 0.05)
    tube("lead", path, radius, braid("lead", (0.05, 0.05, 0.055) if dark else (0.8, 0.8, 0.8), pitch=0.09, sheen=1.0 if dark else 0.5))
    tangent = (path[-1] - path[-4]).normalized()
    transform(usb, axis_frame(path[-1] - tangent * 0.12, tangent, V((0, 0, 1))).inverted())
    return V((0, 0, 1))

def recolor(mat, color, rough=None, metal=0.0, coat=0.0):
    """Replaces a downloaded material's colour (and any printed artwork in its texture) with a flat finish, keeping its normal map."""
    tree = mat.node_tree
    bsdf = next(n for n in tree.nodes if n.type == 'BSDF_PRINCIPLED')
    values = {"Base Color": (*color, 1), "Metallic": metal}
    if rough is not None:
        values["Roughness"] = rough
    for name, value in values.items():
        for edge in list(bsdf.inputs[name].links):
            tree.links.remove(edge)
        bsdf.inputs[name].default_value = value
    bsdf.inputs["Coat Weight"].default_value = coat
    bsdf.inputs["Coat Roughness"].default_value = 0.2

def keyboard_scene(dark):
    parts = import_model("mk5")
    caps = material("caps", (0.03, 0.03, 0.033) if dark else (0.92, 0.92, 0.9), 0.42, coat=0.1)
    case = material("case", (0.025, 0.025, 0.028) if dark else (0.86, 0.86, 0.85), 0.35, coat=0.2)
    knob = material("knob", (0.08, 0.08, 0.09) if dark else (0.8, 0.81, 0.82), 0.25, metal=1, aniso=0.5)
    for ob in parts:
        names = [m.name for m in ob.data.materials if m]
        for i, name in enumerate(names):
            key = name.lower()
            # Every keycap gets one colour; that also drops the accent keys and the maker's logo key.
            ob.data.materials[i] = case if "case" in key else knob if "knob" in key else ob.data.materials[i] if "plate" in key else caps
    return V((0, 0, 1))

def mouse_scene(dark):
    parts = import_model("ms7")
    shell = (0.024, 0.024, 0.026) if dark else (0.93, 0.93, 0.92)
    done = set()
    for ob in parts:
        for mat in ob.data.materials:
            if not mat or mat.name in done:
                continue
            done.add(mat.name)
            key = mat.name.lower()
            # Flat colours drop the printed logo and the red accents in the textures.
            if key.startswith("roll"):
                recolor(mat, (0.05, 0.05, 0.055) if dark else (0.75, 0.75, 0.76), 0.5)
            elif key in ("bottom", "slide", "laser", "laser.001", "material"):
                recolor(mat, (0.03, 0.03, 0.033) if dark else (0.8, 0.8, 0.8), 0.55)
            else:
                recolor(mat, shell, 0.55, coat=0.0) if dark else recolor(mat, shell, 0.36, coat=0.08)
    # Front (scroll wheel) up.
    transform(parts, Matrix.Rotation(math.pi, 4, 'Z'))
    return V((0, 0, 1))

def headphones_scene(dark):
    parts = import_model("hp3")
    body = (0.028, 0.028, 0.03) if dark else (0.9, 0.9, 0.89)
    for ob in list(parts):
        name = ob.data.materials[0].name if ob.data.materials else ""
        # The headband decals are the maker's lettering; button icons and LEDs go too.
        if name in ("Material.002", "Material.003", "Material.004", "Material.005", "Material.006", "Lamp"):
            parts.remove(ob)
            bpy.data.objects.remove(ob)
    done = set()
    for ob in parts:
        for mat in ob.data.materials:
            if not mat or mat.name in done:
                continue
            done.add(mat.name)
            key = mat.name.lower()
            if "leather" in key:
                recolor(mat, [c * 0.94 for c in body], 0.6)
            elif "mesh" in key:
                recolor(mat, [c * 0.8 for c in body], 0.7)
            elif "black" in key:
                recolor(mat, (0.02, 0.02, 0.022), 0.5)
            elif "metal" in key or key == "material.007":
                recolor(mat, (0.2, 0.2, 0.21) if dark else (0.78, 0.78, 0.79), 0.3, metal=1)
            elif "gloss" in key:
                recolor(mat, body, 0.2, coat=0.3)
            else:
                recolor(mat, body, 0.42)
    return V((1.0, 0, 0))

def frame(direction, lens=100, objects=None):
    objects = objects or [o for o in bpy.context.scene.objects if o.type == 'MESH']
    lo, hi = bounds(objects)
    center, radius = (lo + hi) / 2, (hi - lo).length / 2
    camera = link(bpy.data.objects.new("camera", bpy.data.cameras.new("camera")))
    camera.data.lens = lens
    distance = radius / math.tan(math.atan(18 / lens)) * 1.05
    camera.location = center + direction * distance
    hint = V((0, 1, 0)) if abs(direction.z) > 0.9 else V((0, 0, 1))
    side = (-direction).cross(hint).normalized()
    upward = side.cross(-direction)
    camera.rotation_euler = Matrix((side, upward, direction)).transposed().to_euler()
    camera.data.clip_start, camera.data.clip_end = distance * 0.01, distance * 4
    bpy.context.scene.camera = camera
    rotation = camera.rotation_euler.to_matrix()
    right, up, toward = rotation.col[0], rotation.col[1], rotation.col[2]
    # An overhead softbox (what flat metal and gloss reflect toward the camera), a soft key from the top left,
    # broad fill, and two grazing rims that outline dark products.
    for offset, power, size in (((0.0, 0.08, 1.0), 0.7, 1.6), ((-0.5, 0.7, 1.0), 0.8, 1.2), ((0.9, -0.2, 0.7), 0.3, 1.5), ((0.1, 1.0, 0.15), 0.6, 0.8), ((-1.0, -0.6, 0.15), 0.4, 0.8)):
        place = V(offset).normalized()
        data = bpy.data.lights.new("light", 'AREA')
        data.shape, data.size = 'DISK', radius * size
        reach = distance * 0.9
        data.energy = power * 2.2 * reach ** 2
        light = link(bpy.data.objects.new("light", data))
        light.location = center + (right * place.x + up * place.y + toward * place.z) * reach
        light.rotation_euler = (center - light.location).to_track_quat('-Z', 'Y').to_euler()

def crop_and_save(raw, out):
    image = bpy.data.images.load(raw)
    w, h = image.size
    pixels = np.array(image.pixels[:], dtype=np.float32).reshape(h, w, 4)
    ys, xs = np.nonzero(pixels[:, :, 3] > 1 / 255)
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    assert x0 > 0 and y0 > 0 and x1 < w and y1 < h, f"{out} touches the frame edge"
    content = pixels[y0:y1, x0:x1]
    pad = int(round(BORDER * max(content.shape[:2])))
    canvas = np.zeros((content.shape[0] + 2 * pad, content.shape[1] + 2 * pad, 4), dtype=np.float32)
    canvas[pad:pad + content.shape[0], pad:pad + content.shape[1]] = content
    result = bpy.data.images.new(os.path.basename(out), canvas.shape[1], canvas.shape[0], alpha=True)
    result.pixels[:] = canvas.ravel()
    result.filepath_raw = out
    result.file_format = 'PNG'
    result.save()

SCENES = {}
NEUTRAL = {"ethernet"}
for kind in ("usb-c", "thunderbolt-4", "thunderbolt-5", "magsafe"):
    for shade in ("light", "dark"):
        SCENES[f"{kind}-{shade}"] = (lambda dark, k=kind: cable_scene(k, dark), shade == "dark")
for kind, builder in (("charger", charger_scene), ("keyboard", keyboard_scene), ("mouse", mouse_scene), ("hub", hub_scene), ("headphones", headphones_scene)):
    for shade in ("light", "dark"):
        SCENES[f"{kind}-{shade}"] = (builder, shade == "dark")
SCENES["ethernet"] = (ethernet_scene, False)

os.makedirs(OUT, exist_ok=True)
for name, (builder, dark) in SCENES.items():
    if ONLY and name not in ONLY:
        continue
    reset()
    # White products are exposed brighter, as a product photographer would; black ones keep the darker exposure.
    bpy.context.scene.view_settings.exposure = 1.15 if dark or name in NEUTRAL else 1.75
    direction = builder(dark)
    frame(direction)
    raw = os.path.join(OUT, f".{name}-raw.png")
    bpy.context.scene.render.filepath = raw
    bpy.ops.render.render(write_still=True)
    crop_and_save(raw, os.path.join(OUT, f"{name}.png"))
    os.remove(raw)
    print("RENDERED", name)
