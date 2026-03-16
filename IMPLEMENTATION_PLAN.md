# PK3 Runtime Implementation Plan

This file is a working checklist for turning this repo into a PK3/BSP-native runtime library with a thin viewer on top.

## Rules

- Keep PK3/BSP as the native map format for now.
- Keep parsing/runtime code independent from raylib.
- Keep the viewer building as a debug client while internals change.
- Use `rlImGui` for in-engine tooling and editor UI work.
- Prefer finishing vertical slices over adding partial subsystems everywhere.

## Phase 1: Core Split

- [x] Separate engine-facing code from viewer/raylib code.
- [x] Define plain Zig runtime data structures for BSP, entities, scene data, and collision data.
- [x] Move raylib-specific mesh/material upload behind a renderer boundary.
- [x] Keep the current viewer functional after the split.

## Phase 2: Complete BSP Parsing

- [ ] Expand `bsp.zig` to parse all required lumps:
- [x] `entities`
- [x] `planes`
- [x] `nodes`
- [x] `leaves`
- [x] `leafsurfaces`
- [x] `leafbrushes`
- [x] `models`
- [x] `brushes`
- [x] `brushsides`
- [x] `effects`
- [x] `lightvols`
- [x] `visdata`
- [x] Keep existing face/lightmap parsing working.
- [x] Add validation helpers for lump bounds and cross-references.

## Phase 3: Entity System

- [x] Parse the entity lump into key/value entity records.
- [x] Add typed helpers for common fields: classname, origin, angles, model, target, targetname.
- [x] Build a small entity query API for the viewer and future game runtime.
- [x] Verify common map entities can be inspected from code.

## Phase 4: Collision Runtime

- [x] Introduce a `collision` module with brush/plane based world collision.
- [x] Build brush extraction from BSP brush and brushside lumps.
- [x] Support contents flags and basic material/content queries.
- [x] Implement `pointContents`.
- [x] Implement raycast/segment trace.
- [x] Implement swept AABB trace.
- [ ] Expand the first collision debug/test pass to cover more brush edge cases.

## Phase 5: Scene Extraction

- [x] Introduce a backend-agnostic `scene` layer derived from BSP + entities.
- [x] Extract static world surfaces into scene batches/material references.
- [x] Add BSP submodel extraction.
- [x] Add entity-driven scene objects for `misc_model` and other common placements.
- [x] Keep renderer input based on scene data, not raw BSP internals.

## Phase 6: Shader / Material Runtime

- [x] Split shader script parsing out of the current texture cache logic.
- [x] Represent shader stages as plain data.
- [ ] Support a first real subset:
- [x] `map`
- [x] `clampmap`
- [x] `animMap`
- [x] `blendFunc`
- [x] `alphaFunc`
- [x] `rgbGen`
- [x] `alphaGen`
- [x] `tcMod`
- [x] `cull`
- [x] `surfaceparm`
- [x] sky
- [x] fog
- [x] autosprite or equivalent billboard handling
- [x] Wire time-based stage evaluation into rendering so animated materials work.

## Phase 7: Model Support

- [ ] Add MD3 parsing/loading in a standalone module.
- [ ] Instantiate MD3 models from entity data.
- [ ] Support BSP submodels as separate render/collision objects.
- [ ] Handle basic transform/origin/angles for placed models.

## Phase 8: Visibility and Lighting

- [x] Parse and expose BSP visibility data from `visdata`.
- [x] Add leaf/node traversal utilities.
- [x] Add PVS-based culling hooks for the renderer.
- [x] Add frustum culling on top of world-batch visibility.
- [ ] Parse and expose light volume data for dynamic object lighting.
- [ ] Add viewer debug modes for leaves/PVS/light volumes.

## Phase 9: Renderer Upgrade

- [ ] Change the renderer to consume scene/material runtime data.
- [ ] Preserve static lightmap rendering.
- [ ] Add material stage execution for alpha/additive/animated surfaces.
- [x] Add sky/fog/billboard rendering paths.
- [ ] Add model rendering for MD3 and BSP submodels.

## Phase 10: Tooling Base

- [ ] Add debug overlays for entities, collision brushes, submodels, and missing assets.
- [x] Add a first scene-object/submodel inspection flow in the viewer.
- [x] Integrate `rlImGui` as the tooling UI layer for inspector/editor work.
- [ ] Use that as the base for later editor work instead of jumping to full editing immediately.

## Immediate Execution Order

- [x] Refactor the project into backend-agnostic core modules plus viewer glue.
- [x] Expand BSP parsing to all required lumps.
- [x] Implement entity parsing.
- [x] Implement collision world creation and first trace APIs.
- [x] Convert the viewer to consume the new core structures.

## Current Focus

- [ ] Extend the shader/material runtime beyond the first animated-stage subset.
