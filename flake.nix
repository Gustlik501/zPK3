{
  description = "Development shell for zPK3";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f:
        lib.genAttrs systems (system:
          f (import nixpkgs {
            inherit system;
          }));
    in
    {
      devShells = forAllSystems (pkgs:
        let
          raylibBuildDeps = with pkgs; [
            alsa-lib
            libGL
            libpulseaudio
            libx11
            libxcursor
            libxext
            libxfixes
            libxi
            libxinerama
            libxkbcommon
            libxrandr
            libxrender
            mesa
            pkg-config
            wayland
          ];
          includePath = lib.concatStringsSep ":" (map (pkg: "${pkg}/include") raylibBuildDeps);
          libraryPath = lib.makeLibraryPath raylibBuildDeps;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig_0_15
            ] ++ raylibBuildDeps;

            C_INCLUDE_PATH = includePath;
            LD_LIBRARY_PATH = libraryPath;
            LIBRARY_PATH = libraryPath;
          };
        });
    };
}
