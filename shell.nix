{
  pkgs ? import <nixpkgs> { },
}:
pkgs.mkShell {
  packages = with pkgs; [
    libGLX
    xorg.libX11
    xorg.libXcursor
    xorg.libXext
    xorg.libXfixes
    xorg.libXi
    xorg.libXinerama
    xorg.libXrandr
    xorg.libXrender
    python3 # Apparently needed to build for web
    zig
  ];

  shellHook = ''
    unset ZIG_GLOBAL_CACHE_DIR
  '';
}
