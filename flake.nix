{
  description = "drovr: hand tasks from Claude Code to headless workers on cheaper Anthropic-compatible backends";

  outputs =
    { self }:
    {
      homeManagerModules.default = ./module.nix;
      homeManagerModules.drovr = ./module.nix;
    };
}
