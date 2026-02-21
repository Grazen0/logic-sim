{
  lib,
  stdenv,
  callPackage,

  buildPackages,
  libGLX,
  libx11,
  libxcursor,
  libxext,
  libxfixes,
  libxi,
  libxinerama,
  libxrandr,
  libxrender,
  makeWrapper,
  python3,
  zig,
}:
stdenv.mkDerivation {
  pname = "logic-sim";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  nativeBuildInputs = [
    makeWrapper
    python3 # Apparently needed to build for web
    zig
  ];

  buildInputs = [
    buildPackages.libGLX
    buildPackages.libx11
    buildPackages.libxcursor
    buildPackages.libxext
    buildPackages.libxfixes
    buildPackages.libxi
    buildPackages.libxinerama
    buildPackages.libxrandr
    buildPackages.libxrender
  ];

  postConfigure = ''
    ln -s ${callPackage ./deps.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
  '';

  postInstall =
    let
      libs = lib.makeLibraryPath [
        libGLX
        libx11
        libxcursor
        libxext
        libxfixes
        libxi
        libxinerama
        libxrandr
        libxrender
      ];
    in
    ''
      wrapProgram $out/bin/logic-sim --set LD_LIBRARY_PATH '${libs}'
    '';

  meta = with lib; {
    description = "A logic simulator written in Zig and powered by Raylib.";
    website = "https://logic-sim.grazen.xyz";
    license = licenses.gpl3;
    mainProgram = "logic-sim";
  };
}
