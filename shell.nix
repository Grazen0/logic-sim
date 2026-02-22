{
  mkShell,
  logic-sim,
  python3,
}:
mkShell {
  inputsFrom = [ logic-sim ];

  packages = [
    python3 # Needed for web build
  ];
}
