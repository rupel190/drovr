# drovr — hand tasks from your Claude Code session to headless Claude Code workers on
# cheaper Anthropic-compatible backends. Workers run --restricted with five file tools
# and an empty config, in a worktree of HEAD (public or allowlisted repos) or a
# prepared scratch folder. The answer comes back as one message.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.programs.drovr;

  # One `claude-<name>` per provider: Claude Code pointed at that endpoint. The key is
  # read from keyFile at launch, never baked into the store.
  mkWrapper =
    name: p:
    pkgs.writeShellApplication {
      name = "claude-${name}";
      text = ''
        key=${lib.escapeShellArg p.keyFile}
        [ -r "$key" ] || {
          echo "claude-${name}: $key not readable" >&2
          exit 1
        }
        ${p.authVar}="$(<"$key")"
        export ${p.authVar}
        export ANTHROPIC_BASE_URL=${lib.escapeShellArg p.baseUrl}
        export ANTHROPIC_MODEL=${lib.escapeShellArg p.model}
        ${lib.optionalString (p.smallModel != null) ''
          export ANTHROPIC_DEFAULT_HAIKU_MODEL=${lib.escapeShellArg p.smallModel}
        ''}
        export CLAUDE_WORKER=1
        # The default (10 retries, growing waits) turns a bad key into minutes of silence.
        export CLAUDE_CODE_MAX_RETRIES=3
        exec ${lib.getExe cfg.claudePackage} "$@"
      '';
    };

  wrappers = lib.mapAttrsToList mkWrapper cfg.providers;

  drovr = pkgs.writeShellApplication {
    name = "drovr";
    runtimeInputs = wrappers ++ [
      pkgs.jq
      pkgs.git
      pkgs.coreutils
      pkgs.gnused
      pkgs.util-linux # setsid
    ];
    text = ''
      DROVR_ALLOWED=${lib.escapeShellArg (lib.concatLines cfg.allowedRepos)}
      DROVR_PROVIDERS=${lib.escapeShellArg (lib.concatStringsSep " " (lib.attrNames cfg.providers))}
      DROVR_DEFAULT=${lib.escapeShellArg cfg.defaultProvider}
    ''
    + builtins.readFile ./drovr.sh;
  };

  provider = lib.types.submodule {
    options = {
      baseUrl = lib.mkOption {
        type = lib.types.str;
        description = "Anthropic-compatible endpoint (ANTHROPIC_BASE_URL).";
        example = "https://api.deepseek.com/anthropic";
      };
      model = lib.mkOption {
        type = lib.types.str;
        description = "Main model id (ANTHROPIC_MODEL).";
        example = "deepseek-v4-pro";
      };
      smallModel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Background-task model (ANTHROPIC_DEFAULT_HAIKU_MODEL); null keeps the endpoint's own mapping.";
      };
      keyFile = lib.mkOption {
        type = lib.types.str;
        description = "File holding the API key, read at launch (e.g. an agenix or sops-nix secret path).";
        example = "/run/agenix/deepseek-api-key";
      };
      authVar = lib.mkOption {
        type = lib.types.str;
        default = "ANTHROPIC_AUTH_TOKEN";
        description = "Variable the key goes into (ANTHROPIC_AUTH_TOKEN sends a Bearer header, ANTHROPIC_API_KEY sends x-api-key).";
      };
    };
  };
in
{
  options.programs.drovr = {
    enable = lib.mkEnableOption "drovr, headless Claude Code workers on Anthropic-compatible backends";

    claudePackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.claude-code;
      defaultText = lib.literalExpression "pkgs.claude-code";
      description = "Claude Code package the workers run.";
    };

    providers = lib.mkOption {
      type = lib.types.attrsOf provider;
      default = { };
      description = "Anthropic-compatible backends; each becomes a claude-<name> wrapper.";
    };

    defaultProvider = lib.mkOption {
      type = lib.types.str;
      default = "deepseek";
      description = "Provider used when `drovr run` gets no --via.";
    };

    # Default-deny: everything a worker reads is sent to its provider. Public repos
    # qualify without being listed.
    allowedRepos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Private repo roots (and everything under them) where drovr may start workers; each also needs a DROVR.md.";
    };

    weztermHelper = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install integrations/wezterm.lua as ~/.local/share/drovr/wezterm.lua for a status-bar summary.";
    };

    installSkill = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the drovr skill as ~/.claude/skills/drovr/SKILL.md.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.providers ? ${cfg.defaultProvider};
        message = "programs.drovr.defaultProvider '${cfg.defaultProvider}' is not in programs.drovr.providers";
      }
    ];

    home.packages = wrappers ++ [ drovr ];

    home.file.".claude/skills/drovr/SKILL.md" = lib.mkIf cfg.installSkill { source = ./SKILL.md; };
    home.file.".local/share/drovr/wezterm.lua" = lib.mkIf cfg.weztermHelper {
      source = ./integrations/wezterm.lua;
    };
  };
}
