# Quake 3 PK3 Viewer

Modular Quake 3 BSP/PK3 viewer built with Zig and raylib.

## Layout

- `src/` app shell plus reusable Quake 3 PK3, BSP, image, and renderer modules
- `assets/maps/` free test packs
- `vendor/raylib-zig/lib/` vendored Zig bindings

## Build

```sh
zig build quake3_viewer_build
```

```sh
zig build quake3_viewer
```

Example map:

```sh
zig build quake3_viewer -- assets/maps maps/oacmpdm1.bsp
```
