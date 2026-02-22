{
  lib,
  stdenv,
  callPackage,

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
  zig,
}:
let
  xlibs = [
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
stdenv.mkDerivation {
  pname = "logic-sim";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  nativeBuildInputs = [
    makeWrapper
    zig
  ];

  buildInputs = xlibs;

  postConfigure = ''
    ln -s ${callPackage ./deps.nix { }} $ZIG_GLOBAL_CACHE_DIR/p
  '';

  postInstall = ''
    wrapProgram $out/bin/logic-sim --set LD_LIBRARY_PATH '${lib.makeLibraryPath xlibs}'
  '';

  meta = with lib; {
    description = "A logic simulator written in Zig and powered by Raylib.";
    website = "https://logic-sim.grazen.xyz";
    license = licenses.gpl3;
    mainProgram = "logic-sim";
  };
}
