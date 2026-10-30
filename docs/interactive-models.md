# Interactive models in chat

Status: portable model preview implemented on Apple, Android, and Windows
(Windows build still needs validation on a Windows machine).

Android live check (2026-10-30): a signed-in Codex chat produced a 110,076-byte
purple rocket GLB, reported zero glTF validator errors and warnings, and
attached it to the reply. The Android viewer displayed it inline; orbit and
Reset view worked in the emulator. Small models up to 1 MiB open automatically
over a direct route. A relayed transfer asks before using allowance, and a
verified cached copy reopens without another allowance request. The agent's
standing instruction now offers self-contained GLB when a 3D preview is
requested and explains which engine-native assets require export.

| File | Preview path | Practical note |
| --- | --- | --- |
| `.glb` | Bundled offline renderer | Best single-file exchange from Godot, Unity, Unreal, or Blender. Textures can travel inside the file. |
| `.gltf` | Bundled offline renderer | Embedded data works. A file that points to separate buffers or textures needs those files packaged together; external network paths are blocked. |
| `.fbx` | Bundled offline renderer | Geometry and embedded materials where the loader understands them. Some proprietary FBX features, linked textures, and animation setups need an engine export. |
| `.obj`, `.stl`, `.ply` | Bundled offline renderer | Geometry preview; OBJ material sidecars are not loaded from a chat attachment. |
| `.usd`, `.usda`, `.usdc`, `.usdz` | Apple Model I/O and SceneKit | Apple only at present. USDZ is the useful packaged form. |
| Godot `.tscn`, Unity `.prefab`/`.unity`, Unreal `.uasset` | Download only | These are project assets with engine-specific references. A faithful preview needs export through the owning engine. |

The renderer is bundled in `apps/charts/runtime` with a pinned Three.js
dependency and its license notice. It loads from a local virtual origin with a
restrictive content policy; clients block navigation and external network
loads. A 12 MB limit bounds inline preview work; the original file remains
downloadable. Drag to orbit, pinch or scroll to zoom, and drag with the
secondary pointer to pan.
The viewer draws only while the camera or viewport changes. Its 44-point
Reset view control returns to the initial framing.

Next steps: verify the Windows view on Windows hardware; test real project
exports from each engine, especially FBX materials and GLB skinning; make
paired sidecar assets available from an approved project rather than from the
network; and add an engine-hosted export action for project-native files. An
export must never execute arbitrary scene scripts just to render a preview.
